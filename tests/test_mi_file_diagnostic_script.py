"""Checks for sql/monitoring/azure_sql_mi_file_diagnostic_v2-4.sql.

The script runs only on Azure SQL Managed Instance, so these tests don't run
it. They read it as text and check what can go wrong without an instance:

* Its published-limit tables match scripts/mi_capacity.py, so the live
  diagnostic and the run collector judge a load against the same numbers.
* None of the outdated values from v2.3 have come back.
* It stays read-only and keeps its design: the five-second sample, and file
  expansion statements that are commented out.

Portable query fragments also run against SQLite in memory to check missing
metadata, unknown log rates, and database shares. This does not execute the
whole script or validate SQL Server-specific runtime behavior.
"""
import re
import sqlite3
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import mi_capacity as m

SCRIPT = ROOT / "sql" / "monitoring" / "azure_sql_mi_file_diagnostic_v2-4.sql"
TEXT = SCRIPT.read_text(encoding="utf-8")


def values_after(marker: str) -> list:
    """The rows of the INSERT ... VALUES that follows ``marker``, as tuples of numbers."""
    start = TEXT.index(marker)
    block = TEXT[start:TEXT.index(";", start)]
    return [tuple(float(n) for n in row.split(","))
            for row in re.findall(r"\(([\d\s.,]+)\)", block.split("VALUES", 1)[1])]


def code_only(text: str) -> str:
    """The script without comments or string literals."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"--[^\n]*", "", text)
    return re.sub(r"N?'(?:[^']|'')*'", "''", text)


class PublishedLimitTests(unittest.TestCase):
    def test_file_limits_match_the_collector(self):
        rows = values_after("INSERT #GP_File_Limits")
        script = [(size, iops, mib) for _order, size, iops, mib in rows]
        self.assertEqual(script, [tuple(float(v) for v in row) for row in m.GP_CLASSIC_FILE_LIMITS])

    def test_next_gen_caps_match_the_collector(self):
        self.assertEqual(values_after("INSERT #NextGen_VCore_Limits"),
                         [tuple(float(v) for v in row) for row in m.NEXT_GEN_VCORE_LIMITS])

    def test_instance_constants_match_the_collector(self):
        self.assertIn(f"vCores * {m.BC_IOPS_PER_VCORE} > {m.BC_MAXIMUM_IOPS}", TEXT)
        self.assertIn(f"* {m.NEXT_GEN_IOPS_PER_RESERVED_GB} < {m.NEXT_GEN_MINIMUM_IOPS}", TEXT)
        self.assertIn(f"/ {float(m.NEXT_GEN_IOPS_PER_MB_PER_SECOND)} < {m.NEXT_GEN_MINIMUM_MB_PER_SECOND}", TEXT)
        for storage, (per_vcore, caps) in m.LOG_RATE_LIMITS.items():
            for cap in set(caps.values()):
                self.assertRegex(TEXT, rf"vCores \* {per_vcore} > {int(cap)}", f"{storage} log cap {cap}")

    def test_thresholds_match_the_collector(self):
        self.assertIn(f">= {int(m.NEAR_LIMIT_PERCENT)}", TEXT)
        self.assertIn(f">{int(m.SLOW_IO_MS)}", TEXT)


class OutdatedValueTests(unittest.TestCase):
    def test_v2_3_file_brackets_are_gone(self):
        code = code_only(TEXT)
        for old in ("<= 32 THEN 120", "<= 64 THEN 240", "THEN 1100", "'120 IOPS'", "'1100 IOPS'"):
            self.assertNotIn(old, code)

    def test_v2_3_vcore_table_and_size_guess_are_gone(self):
        code = code_only(TEXT)
        self.assertNotIn("WHEN vCores = 8 THEN 8000", code)
        self.assertNotIn("> 16384", code)
        self.assertNotIn("vCores * 1600", code)


class DesignTests(unittest.TestCase):
    def test_it_stays_read_only(self):
        # Every write goes to a temporary table (#...), directly or through an
        # alias defined as "#table AS alias". The INSERT inside the per-database
        # dynamic SQL is a string here; it writes to #MI_File_Stats.
        code = code_only(TEXT).upper()
        aliases = dict((alias, table) for table, alias in re.findall(r"(#\w+)\s+AS\s+(\w+)", code))
        writes = re.findall(r"\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|DROP|CREATE|ALTER)\b\s+"
                            r"(?:TABLE\s+)?(?:IF\s+EXISTS\s+)?(?:INTO\s+)?(\S+)", code)
        self.assertTrue(writes)
        for verb, target in writes:
            self.assertNotEqual(verb, "ALTER", f"ALTER outside a comment: {target}")
            target = aliases.get(target.rstrip(";"), target)
            self.assertTrue(target.startswith("#"), f"{verb} touches {target}, which is not a temporary table")
        self.assertIn("INSERT #MI_FILE_STATS", TEXT.upper())

    def test_it_keeps_the_five_second_sample(self):
        self.assertIn("WAITFOR DELAY '00:00:05';", TEXT)

    def test_expansion_statements_stay_commented(self):
        self.assertIn("'-- ALTER DATABASE '", TEXT)

    def test_storage_type_is_a_setting_not_a_guess(self):
        self.assertIn("DECLARE @GeneralPurposeStorage nvarchar(10) = NULL;", TEXT)

    def test_classification_names_match_the_collector(self):
        for name in ("FILE_LEVEL", "INSTANCE_LEVEL", "MIXED", "NOT_PROVEN", "NOT_ASSESSED"):
            self.assertIn(f"'{name}'", TEXT)
            self.assertIn(name, m.CLASSIFICATION_MEANING)


class MissingMetadataTests(unittest.TestCase):
    def setUp(self):
        self.connection = sqlite3.connect(":memory:")
        self.addCleanup(self.connection.close)
        self.connection.row_factory = sqlite3.Row
        self.connection.create_function("CONCAT", -1, lambda *args: "".join(str(arg) for arg in args))
        self.connection.executescript("""
            CREATE TABLE databases (database_id INTEGER, name TEXT, state_desc TEXT);
            INSERT INTO databases VALUES (5, 'LoadTest', 'ONLINE'), (6, 'OtherLoad', 'ONLINE');
            CREATE TABLE MI_File_Stats (
                DatabaseID INTEGER, FileID INTEGER, DatabaseName TEXT, LogicalName TEXT,
                FileType TEXT, FileSizeGB REAL, SpaceUsedGB REAL, FreeSpaceInFileGB REAL,
                PRIMARY KEY (DatabaseID, FileID)
            );
            INSERT INTO MI_File_Stats VALUES
                (5, 1, 'LoadTest', 'data', 'ROWS', 100, 70, 30),
                (5, 2, 'LoadTest', 'log', 'LOG', 20, 10, 10);
            CREATE TABLE FileDeltas (
                database_id INTEGER, file_id INTEGER, Reads_Delta INTEGER,
                Writes_Delta INTEGER, Live_Write_MiBps REAL
            );
            INSERT INTO FileDeltas VALUES (5, 1, 0, 500, 1), (5, 2, 0, 250, 5), (6, 1, 0, 500, 10);
        """)

    def execute_fragment(self, sql, parameters=()):
        # Only names, Unicode literal prefixes, and the equivalent null function
        # differ in these otherwise portable SQL Server/SQLite query fragments.
        sql = re.sub(r"#(\w+)", r"\1", sql)
        sql = sql.replace("sys.databases", "databases").replace("N'", "'").replace("ISNULL(", "IFNULL(")
        return self.connection.execute(sql, parameters)

    def retain_missing_files(self):
        start = TEXT.index("INSERT INTO #MI_File_Stats", TEXT.index("-- Keep sampled files"))
        end = TEXT.index(";", start)
        self.execute_fragment(TEXT[start:end])

    def test_sampled_files_without_metadata_are_retained_without_duplicates(self):
        self.retain_missing_files()
        row = self.connection.execute("SELECT * FROM MI_File_Stats WHERE DatabaseID = 6").fetchone()
        self.assertEqual(row["LogicalName"], "file 1")
        for field in ("FileType", "FileSizeGB", "SpaceUsedGB", "FreeSpaceInFileGB"):
            self.assertIsNone(row[field])
        self.retain_missing_files()
        self.assertEqual(self.connection.execute("SELECT COUNT(*) FROM MI_File_Stats").fetchone()[0], 3)

    def test_unknown_active_file_type_does_not_produce_a_partial_instance_log_rate(self):
        self.retain_missing_files()
        expression = TEXT.split("DECLARE @ObservedInstanceLogWriteMiBps decimal(19,2) =", 1)[1].split(";", 1)[0]
        self.assertIsNone(self.execute_fragment("SELECT " + expression).fetchone()[0])
        self.connection.execute("UPDATE FileDeltas SET Writes_Delta = 0 WHERE database_id = 6")
        self.assertEqual(self.execute_fragment("SELECT " + expression).fetchone()[0], 5)

    def test_database_shares_include_hidden_files_and_their_log_rate_is_unknown(self):
        self.retain_missing_files()
        self.connection.executescript("""
            CREATE TABLE FileAnalysis AS
            SELECT f.DatabaseID, f.DatabaseName, f.FileType,
                   d.Reads_Delta / 5.0 AS Read_IOPS, d.Writes_Delta / 5.0 AS Write_IOPS,
                   (d.Reads_Delta + d.Writes_Delta) / 5.0 AS Live_File_IOPS,
                   0.0 AS Live_Read_MiBps, d.Live_Write_MiBps
            FROM MI_File_Stats AS f
            JOIN FileDeltas AS d ON d.database_id = f.DatabaseID AND d.file_id = f.FileID;
        """)
        start = TEXT.index(";WITH DatabaseActivity AS")
        end = TEXT.index("ORDER BY Total_IOPS DESC;", start) + len("ORDER BY Total_IOPS DESC;")
        rows = self.execute_fragment(TEXT[start:end], {"TargetDatabaseID": 5, "AllObservedIOPS": 250}).fetchall()
        self.assertEqual({row["DatabaseName"] for row in rows}, {"LoadTest", "OtherLoad"})
        self.assertEqual(sum(row["Percent_Of_Observed_Instance_IOPS"] for row in rows), 100)
        hidden = next(row for row in rows if row["DatabaseName"] == "OtherLoad")
        self.assertEqual(hidden["Total_IOPS"], 100)
        self.assertIsNone(hidden["Log_Write_MiBps"])
        target = next(row for row in rows if row["DatabaseName"] == "LoadTest")
        self.assertEqual(target["Log_Write_MiBps"], 5)

    def test_missing_details_prevent_a_healthy_verdict_for_every_storage_model(self):
        expression = TEXT.split("DECLARE @StorageLimitsKnown bit =", 1)[1].split(";", 1)[0]
        for storage in ("classic", "next-gen", "business-critical"):
            for missing, expected in ((1, 0), (0, 1)):
                with self.subTest(storage=storage, missing=missing):
                    parameters = {"StorageModel": storage, "MaxInstanceIOPS": 1000,
                                  "FilesWithMissingDetails": missing}
                    self.assertEqual(self.execute_fragment("SELECT " + expression, parameters).fetchone()[0],
                                     expected)


if __name__ == "__main__":
    unittest.main()
