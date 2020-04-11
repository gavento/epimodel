#!/usr/bin/env python3

import argparse
import logging
from pathlib import Path
from typing import List, Optional, Dict
import pandas as pd

import yaml

import epimodel

from epimodel import Level, RegionDataset
from epimodel.exports.epidemics_org import WebExport, upload_export
from epimodel.gleam import Batch

log = logging.getLogger(__name__)


def import_countermeasures(args):
    log.info(f"Importing countermeasures from {args.SRC} into {args.DEST} ...")
    cms = epimodel.imports.import_countermeasures_csv(args.rds, args.SRC)
    cms.to_csv(args.DEST)
    log.info(
        f"Saved countermeasures to {args.DEST}, {len(cms.columns)} features, "
        f"last day is {cms.index.get_level_values(1).max()}"
    )


def update_johns_hopkins(args):
    log.info("Downloading and parsing CSSE ...")
    csse = epimodel.imports.import_johns_hopkins(args.rds)
    dest = Path(args.config["data_dir"]) / "johns-hopkins.csv"
    csse.to_csv(dest)
    log.info(
        f"Saved CSSE to {dest}, last day is {csse.index.get_level_values(1).max()}"
    )


def update_foretold(args):
    if args.config["foretold_channel"] == "SECRET":
        log.warning(
            "`foretold_channel` in the config file is not set to non-default value."
        )
    else:
        log.info("Downloading and parsing foretold")
        foretold = epimodel.imports.import_foretold(
            args.rds, args.config["foretold_channel"]
        )
        dest = Path(args.config["data_dir"]) / "foretold.csv"
        foretold.to_csv(dest, float_format="%.7g")
        log.info(f"Saved Foretold to {dest}")


def get_cmi(df: pd.DataFrame):
    return df.index.levels[0].unique()


def analyze_data_consistency(
    debug: Optional[None],
    export_regions: List[str],
    models,
    rates_df,
    hopkins,
    foretold,
) -> None:
    codes = {
        "models": get_cmi(models),
        "hopkins": get_cmi(hopkins),
        "foretold": get_cmi(foretold),
        "rates": rates_df.index.unique(),
    }

    union_codes = set()
    any_nan = False
    for source_name, ixs in codes.items():
        if ixs.isna().sum() > 0:
            log.error("Dataset %s contains NaN in index!", source_name)
            any_nan = True
        union_codes.update(ixs)

    if any_nan:
        raise ValueError("Some datasets indexed by NaNs. Fix the source data.")

    df = pd.DataFrame(index=sorted(union_codes))
    for source_name, ixs in codes.items():
        df[source_name] = pd.Series(True, index=ixs)
    df = df.fillna(False)

    log.info("Total data availability, number of locations: %s", df.sum().to_dict())
    log.info("Export requested for %s regions: %s", len(export_regions), export_regions)

    if debug:
        _df = df.loc[export_regions, ["hopkins", "rates"]]
        res = _df.loc[~_df.all(axis=1)].replace({False: "Missing", True: "OK"})
        log.debug(
            "Data presence for hopkins or rates in the following countries: \n%s", res
        )
        breakpoint()

    diff_export_and_models = set(export_regions).difference(get_cmi(models))
    if diff_export_and_models:
        log.error(
            "You requested to export %s but that's not modelled yet.",
            diff_export_and_models,
        )
        raise ValueError(
            f"Regions {diff_export_and_models} not present in modelled data. Remove it from config."
        )

    log.info(
        "From exported regions (N=%s): %s",
        len(export_regions),
        df.loc[export_regions].sum().to_dict(),
    )


def get_df_else_none(df: pd.DataFrame, code) -> Optional[pd.DataFrame]:
    if code in df.index:
        return df.loc[code].sort_index()
    else:
        return None


def get_extra_path(args, name: str) -> Path:
    return Path(args.config["data_dir"]) / args.config["web_export"][name]


def aggregate_countries(
    hopkins: pd.DataFrame, mapping: Dict[str, List[str]]
) -> pd.DataFrame:
    to_append = []
    all_state_codes = []
    for country_code, state_codes in mapping.items():
        log.info(
            "Aggregating hopkins data for %s into a single code %s",
            state_codes,
            country_code,
        )
        aggregated = (
            hopkins.loc[state_codes]
            .reset_index("Date")
            .groupby("Date")
            .sum()
            .assign(Code=country_code)
            .reset_index()
            .set_index(["Code", "Date"])
        )
        to_append.append(aggregated)
        all_state_codes.extend(state_codes)
    return hopkins.drop(index=all_state_codes).append(pd.concat(to_append))


def web_export(args) -> None:
    ex = WebExport(args.config["gleam_resample"], comment=args.comment)

    hopkins = get_extra_path(args, "john_hopkins")
    foretold = get_extra_path(args, "foretold")
    rates = get_extra_path(args, "rates")

    export_regions = sorted(args.config["export_regions"])

    simulation_specs: pd.DataFrame = pd.read_hdf(args.models_file, "simulations")
    models_df: pd.DataFrame = pd.read_hdf(args.models_file, "new_fraction")

    rates_df: pd.DataFrame = pd.read_csv(rates, index_col="Code", keep_default_na=False)

    hopkins_df: pd.DataFrame = pd.read_csv(
        hopkins, index_col=["Code", "Date"], parse_dates=["Date"]
    ).pipe(aggregate_countries, args.config["state_to_country"])
    foretold_df: pd.DataFrame = pd.read_csv(
        foretold, index_col=["Code", "Date"], parse_dates=["Date"]
    )

    analyze_data_consistency(
        args.debug, export_regions, models_df, rates_df, hopkins_df, foretold_df
    )

    for code in export_regions:
        reg = args.rds[code]
        ex.new_region(
            reg,
            models_df.loc[code].sort_index(level="Date"),
            simulation_specs,
            get_df_else_none(rates_df, code),
            get_df_else_none(hopkins_df, code),
            get_df_else_none(foretold_df, code),
        )

    ex.write(args.config["output_dir"])


def web_upload(args):
    c = args.config
    upload_export(
        args.EXPORTED_DIR, c["gs_prefix"], c["gs_url_prefix"], channel=args.channel
    )


def import_batch(args):
    batch = Batch.open(args.BATCH_FILE)
    d = args.rds.data
    regions = d.loc[(d.Level == Level.country) & (d.GleamID != "")].Region.values
    batch.import_sims(
        Path(args.config["gleamviz_sims_dir"]).expanduser(),
        regions,
        resample=args.config["gleam_resample"],
        allow_unfinished=args.allow_missing,
    )


def create_parser():
    ap = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    ap.add_argument("-d", "--debug", action="store_true", help="Debugging logs.")
    ap.add_argument("-C", "--config", default="config.yaml", help="Config file.")
    sp = ap.add_subparsers(title="subcommands", required=True, dest="cmd")

    upp = sp.add_parser(
        "update_johns_hopkins", help="Fetch data from Johns Hopkins CSSE."
    )
    upp.set_defaults(func=update_johns_hopkins)

    upf = sp.add_parser("update_foretold", help="Fetch data from Foretold.")
    upf.set_defaults(func=update_foretold)

    ibp = sp.add_parser("import_gleam_batch", help="Load batch results from GLEAM.")
    ibp.add_argument(
        "BATCH_FILE", help="The batch-*.hdf5 file with batch spec to be updated."
    )
    ibp.add_argument(
        "-M", "--allow-missing", action="store_true", help="Skip missing sim results.",
    )
    ibp.set_defaults(func=import_batch)

    exp = sp.add_parser("web_export", help="Create data export for web.")
    exp.add_argument("-c", "--comment", help="A short comment (to be part of path).")
    exp.add_argument("models_file", help="A result HDF file of import_gleam_batch step")
    exp.set_defaults(func=web_export)

    uplp = sp.add_parser("web_upload", help="Upload data to the configured GCS bucket")
    uplp.add_argument("EXPORTED_DIR", help="The generated export directory.")
    uplp.add_argument(
        "-c",
        "--channel",
        default="staging",
        help="Channel to upload to ('main' for main site).",
    )
    uplp.set_defaults(func=web_upload)

    iftp = sp.add_parser(
        "import_countermeasures", help="Import one CSV file from countermeasures DB."
    )
    iftp.add_argument("SRC", help="Input CSV.")
    iftp.add_argument("DEST", help="Output CSV.")
    iftp.set_defaults(func=import_countermeasures)

    return ap


def main():
    logging.basicConfig(level=logging.INFO)
    args = create_parser().parse_args()
    if args.debug:
        logging.root.setLevel(logging.DEBUG)
    with open(args.config, "rt") as f:
        args.config = yaml.safe_load(f)
    args.rds = RegionDataset.load(Path(args.config["data_dir"]) / "regions.csv")
    args.func(args)


if __name__ == "__main__":
    main()
