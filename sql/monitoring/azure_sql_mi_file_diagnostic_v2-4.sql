/*
================================================================================
VERSION 2.4
Azure SQL MI Storage, File/Instance Capacity, Live Throughput & Latency
================================================================================
Baseline: azure_sql_mi_file_diagnostic_v2-3.sql

What it is for:
Run it by hand, in SSMS, WHILE a load is running. It takes a five-second sample
of every file's I/O on the instance and compares it with the limits Microsoft
publishes for the instance's tier, then says whether the pressure is on one
file, on the whole instance, or not proven. It is a live diagnostic. For the
whole of a recorded test, use the run collector (scripts/collect_run_metrics.py),
which applies the same limits and the same classifications.

Before you run it (SETTINGS, below):
- @GeneralPurposeStorage: 'classic' or 'next-gen' for a General Purpose
  instance. They have different limits and SQL can't tell them apart reliably.
  Azure portal > the managed instance > Compute + storage: if Next-gen General
  Purpose shows as enabled, use 'next-gen'. Leave NULL for Business Critical.
  Left NULL on General Purpose, storage limits are not judged.
- @NextGenProvisionedIOPS: Next-gen only, and only if extra IOPS were bought.

Scope:
- All online databases visible to the executing login, including tempdb.
- The database context where the script starts is marked as the target in
  result set 3.
- Read-only against SQL MI. Uses local temporary tables only.
- File sizes are reported in GiB (1 GiB = 1,073,741,824 bytes), the unit
  Microsoft's file-size brackets use.

Limits (from Microsoft's "Overview of Azure SQL Managed Instance resource
limits" page, https://learn.microsoft.com/azure/azure-sql/managed-instance/resource-limits,
checked 2026-11-16):
- Classic General Purpose, per file (data and log), by file size:
  <=129 GiB 500 IOPS / 100 MiB/s; <=513 GiB 2,300 / 150; <=1,025 GiB 5,000 / 200;
  above that 7,500 / 250 (up to 8 TiB).
- Classic General Purpose, instance: the sum of its files' limits. Microsoft:
  "Max instance IOPS depend on the file layout and distribution of workload.
  As an example, if you create 7 x 1-TB files with max 5 K IOPS each and seven
  small files (smaller than 128 GB) with 500 IOPS each, you can get 38500 IOPS
  per instance (7x5000+7x500) if your workload can use all files. Some IOPS are
  also used for autobackups."
- Next-gen General Purpose, instance: 3 IOPS per GB of reserved storage
  (minimum 300), or the total bought, up to a cap by vCore count; throughput
  = IOPS / 30 MB/s (minimum 75), up to a cap by vCore count.
- Business Critical, instance: 4,000 IOPS per vCore, at most 320,000;
  throughput not limited.
- Instance log write: General Purpose 4.5 MiB/s per vCore, at most 120 MiB/s
  (Next-gen on premium-series hardware: 192). Business Critical 16 MiB/s per
  vCore, at most 160 MiB/s (premium-series: 192).
- Per-database log write on classic General Purpose: Microsoft gives a range,
  22-65 MiB/s depending on log file size, but not which size gets which value.
  The cut-offs this script shows for it are estimates, and are labelled so.
- tempdb: on General Purpose it is on local SSD, outside these storage limits,
  so it gets no file limit and is left out of the instance IOPS totals. On
  Business Critical it shares the instance's IOPS, so it is included.

Changes from v2.3:
- Per-file limits brought in line with Microsoft's page (v2.3 used older
  values: 120 IOPS up to 32 GB, 240 up to 64, 1,100 up to 512 ...).
- Per-file limits now apply to log files as well as data files, and per-file
  throughput (MiB/s) is checked as well as IOPS.
- Classic General Purpose instance ceiling is the sum of its files' limits,
  replacing v2.3's vCore table, which isn't in Microsoft's documentation.
  If any file's size couldn't be read, the ceiling is left unknown rather
  than taken from a partial sum.
- Next-gen General Purpose is stated in SETTINGS instead of guessed from
  reserved storage over 16 TB. Its limits include the 300 IOPS minimum, bought
  IOPS, the vCore caps, and the throughput ceiling.
- Instance log ceiling is correct for Business Critical and Next-gen.
- tempdb is handled by tier, as above.
- Action text names the next file-size step from Microsoft's table, and no
  longer advises more vCores for a classic General Purpose file limit.
- A value that can't be worked out is shown as NULL with the reason in
  Limits_Note, and the classification is NOT_ASSESSED instead of healthy.

Unchanged:
- WAITFOR DELAY '00:00:05' is preserved exactly.
- File expansion statements remain commented. Review them before running any.
- Three result sets, the 70% and 15 ms thresholds, and the classification names.
================================================================================
*/
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET NOCOUNT ON;
SET XACT_ABORT ON;

/* ============================== SETTINGS ============================== */
DECLARE @GeneralPurposeStorage nvarchar(10) = NULL;  -- N'classic' or N'next-gen'; NULL for Business Critical
DECLARE @NextGenProvisionedIOPS int = NULL;          -- Next-gen only: total IOPS, if extra IOPS were bought
/* ====================================================================== */

DECLARE @TargetDatabaseID int = DB_ID();
DECLARE @TargetDatabaseName sysname = DB_NAME();
DECLARE @LimitsSource nvarchar(200) =
    N'https://learn.microsoft.com/azure/azure-sql/managed-instance/resource-limits (checked 2026-11-16)';
DECLARE @NextGenSpec nvarchar(600) =
    N'Next-gen General Purpose (Elastic SAN-backed) offers pooled instance IOPS not tied to individual file size. '
  + N'Verify current limits, regional availability, and service configuration in Microsoft documentation before changing the MI.';

DROP TABLE IF EXISTS #GP_File_Limits;
DROP TABLE IF EXISTS #NextGen_VCore_Limits;
DROP TABLE IF EXISTS #Instance_Config;
DROP TABLE IF EXISTS #MI_File_Stats;
DROP TABLE IF EXISTS #File_IO_Snapshot_1;
DROP TABLE IF EXISTS #File_IO_Snapshot_2;
DROP TABLE IF EXISTS #FileDeltas;
DROP TABLE IF EXISTS #FileAnalysis;

IF @GeneralPurposeStorage IS NOT NULL AND @GeneralPurposeStorage NOT IN (N'classic', N'next-gen')
BEGIN
    RAISERROR(N'@GeneralPurposeStorage must be N''classic'', N''next-gen'', or NULL.', 16, 1);
    RETURN;
END;

/* STEP 0: PUBLISHED LIMITS (see the header for the source) */

-- Classic General Purpose: each data or log file's limit, by its size.
CREATE TABLE #GP_File_Limits
(
    BracketOrder int NOT NULL PRIMARY KEY,
    MaxFileSizeGiB decimal(12,2) NOT NULL,
    FileIOPS int NOT NULL,
    FileMiBps int NOT NULL
);
INSERT #GP_File_Limits (BracketOrder, MaxFileSizeGiB, FileIOPS, FileMiBps)
VALUES (1, 129, 500, 100), (2, 513, 2300, 150), (3, 1025, 5000, 200),
       (4, 2049, 7500, 250), (5, 4097, 7500, 250), (6, 8192, 7500, 250);

-- Next-gen General Purpose: the instance cap for each vCore count.
-- A row applies from MinVCores up to the next row; 56 to 128 share the last.
CREATE TABLE #NextGen_VCore_Limits
(
    MinVCores int NOT NULL PRIMARY KEY,
    MaxIOPS int NOT NULL,
    MaxMBps int NOT NULL
);
INSERT #NextGen_VCore_Limits (MinVCores, MaxIOPS, MaxMBps)
VALUES (4, 6400, 145), (6, 9600, 217), (8, 12800, 290), (10, 16000, 367),
       (12, 19200, 445), (16, 25600, 600), (20, 32000, 665), (24, 38400, 730),
       (32, 51200, 865), (40, 64000, 1152), (48, 76800, 1152), (56, 80000, 1200);

/* STEP 1: INSTANCE CONFIGURATION */
CREATE TABLE #Instance_Config
(
    ServiceTier nvarchar(128),
    HardwareGeneration nvarchar(128),
    HardwareSeries varchar(10) NULL,           -- 'standard', 'premium', or NULL when not recognised
    vCores int,
    TotalInstanceReservedGB decimal(12,2),
    TotalInstanceUsedGB decimal(12,2),
    StorageModel varchar(20) NULL,             -- 'classic', 'next-gen', 'business-critical', or NULL
    MaxInstanceIOPS decimal(19,2) NULL,
    MaxInstanceThroughputMBps decimal(19,2) NULL,
    InstanceCeilingBasis nvarchar(400) NULL,
    EstimatedInstanceLogWriteCeilingMiBps decimal(19,2) NULL,
    LimitsNote nvarchar(2000) NOT NULL DEFAULT (N'')
);

INSERT #Instance_Config (ServiceTier, HardwareGeneration, vCores, TotalInstanceReservedGB, TotalInstanceUsedGB)
SELECT TOP (1)
    sku,
    hardware_generation,
    virtual_core_count,
    CAST(reserved_storage_mb / 1024.0 AS decimal(12,2)),
    CAST(storage_space_used_mb / 1024.0 AS decimal(12,2))
FROM sys.server_resource_stats
ORDER BY end_time DESC;

-- Standard-series reports as Gen5 (Gen6 and Gen7 are the same series on newer
-- processors); premium-series as Gen8.
UPDATE #Instance_Config
SET HardwareSeries =
        CASE
            WHEN LOWER(REPLACE(HardwareGeneration, N' ', N'')) LIKE N'%premium%'
              OR LOWER(REPLACE(HardwareGeneration, N' ', N'')) LIKE N'%gen8%' THEN 'premium'
            WHEN LOWER(REPLACE(HardwareGeneration, N' ', N'')) LIKE N'%gen5%'
              OR LOWER(REPLACE(HardwareGeneration, N' ', N'')) LIKE N'%gen6%'
              OR LOWER(REPLACE(HardwareGeneration, N' ', N'')) LIKE N'%gen7%'
              OR LOWER(REPLACE(HardwareGeneration, N' ', N'')) LIKE N'%standard%' THEN 'standard'
        END,
    StorageModel =
        CASE
            WHEN ServiceTier LIKE N'%Business Critical%' THEN 'business-critical'
            WHEN ServiceTier LIKE N'%General Purpose%' THEN CAST(@GeneralPurposeStorage AS varchar(20))
        END;

-- Instance log write ceiling. Where the hardware series isn't recognised and
-- the two series would give different values, it stays NULL.
UPDATE #Instance_Config
SET EstimatedInstanceLogWriteCeilingMiBps =
        CASE
            WHEN ServiceTier LIKE N'%Business Critical%' THEN
                CASE
                    WHEN HardwareSeries = 'standard' OR vCores * 16.0 <= 160 THEN IIF(vCores * 16.0 > 160, 160, vCores * 16.0)
                    WHEN HardwareSeries = 'premium' THEN IIF(vCores * 16.0 > 192, 192, vCores * 16.0)
                END
            WHEN ServiceTier LIKE N'%General Purpose%' THEN
                CASE
                    WHEN StorageModel = 'classic' OR HardwareSeries = 'standard' OR vCores * 4.5 <= 120
                        THEN IIF(vCores * 4.5 > 120, 120, vCores * 4.5)
                    WHEN StorageModel = 'next-gen' AND HardwareSeries = 'premium'
                        THEN IIF(vCores * 4.5 > 192, 192, vCores * 4.5)
                END
        END;

UPDATE #Instance_Config
SET LimitsNote = LimitsNote + N'Instance log write ceiling unknown: the hardware series is not recognised (or, on General Purpose, the storage type is not set), and the limit differs at this vCore count. '
WHERE EstimatedInstanceLogWriteCeilingMiBps IS NULL;

UPDATE #Instance_Config
SET LimitsNote = LimitsNote + N'General Purpose storage type not set: set @GeneralPurposeStorage to N''classic'' or N''next-gen'' in SETTINGS. Storage limits were not judged. '
WHERE ServiceTier LIKE N'%General Purpose%' AND StorageModel IS NULL;

-- Business Critical: 4,000 IOPS per vCore, at most 320,000. Throughput is not limited.
UPDATE #Instance_Config
SET MaxInstanceIOPS = IIF(vCores * 4000 > 320000, 320000, vCores * 4000),
    InstanceCeilingBasis = N'Business Critical: 4,000 IOPS per vCore, at most 320,000. Throughput not limited.'
WHERE StorageModel = 'business-critical';

-- Next-gen General Purpose: included or bought IOPS, up to the vCore cap.
UPDATE ic
SET MaxInstanceIOPS = x.InstanceIOPS,
    MaxInstanceThroughputMBps = IIF(IIF(x.InstanceIOPS / 30.0 < 75, 75, x.InstanceIOPS / 30.0) > cap.MaxMBps,
                                    cap.MaxMBps, IIF(x.InstanceIOPS / 30.0 < 75, 75, x.InstanceIOPS / 30.0)),
    InstanceCeilingBasis = CONCAT(N'Next-gen General Purpose: ',
                                  IIF(@NextGenProvisionedIOPS IS NULL, N'included IOPS (3 per reserved GB, minimum 300)', N'stated IOPS'),
                                  N', capped at ', cap.MaxIOPS, N' IOPS and ', cap.MaxMBps, N' MB/s for ', ic.vCores, N' vCores.'),
    LimitsNote = LimitsNote
                 + IIF(@NextGenProvisionedIOPS IS NULL,
                       N'Next-gen IOPS assume the included 3 per reserved GB. If extra IOPS were bought, set @NextGenProvisionedIOPS. ',
                       N'')
                 + IIF(@NextGenProvisionedIOPS > cap.MaxIOPS,
                       CONCAT(N'@NextGenProvisionedIOPS is above the ', cap.MaxIOPS, N' IOPS cap for this vCore count; the cap is used. '),
                       N'')
FROM #Instance_Config AS ic
CROSS APPLY (SELECT TOP (1) MaxIOPS, MaxMBps FROM #NextGen_VCore_Limits
             WHERE MinVCores <= ic.vCores ORDER BY MinVCores DESC) AS cap
CROSS APPLY (SELECT CAST(IIF(COALESCE(@NextGenProvisionedIOPS,
                                      IIF(ic.TotalInstanceReservedGB * 3 < 300, 300, ic.TotalInstanceReservedGB * 3)) > cap.MaxIOPS,
                             cap.MaxIOPS,
                             COALESCE(@NextGenProvisionedIOPS,
                                      IIF(ic.TotalInstanceReservedGB * 3 < 300, 300, ic.TotalInstanceReservedGB * 3)))
                         AS decimal(19,2)) AS InstanceIOPS) AS x
WHERE ic.StorageModel = 'next-gen';

UPDATE #Instance_Config
SET LimitsNote = LimitsNote + N'Next-gen limits are not published for this vCore count. '
WHERE StorageModel = 'next-gen' AND MaxInstanceIOPS IS NULL;

/* STEP 2: INSTANCE-WIDE FILE METADATA */
CREATE TABLE #MI_File_Stats
(
    DatabaseID int NOT NULL,
    FileID int NOT NULL,
    DatabaseName sysname NOT NULL,
    LogicalName sysname NOT NULL,
    FileType varchar(10) NULL,
    FileSizeGB decimal(12,2) NULL,             -- GiB: size in 8 KB pages / 131,072
    SpaceUsedGB decimal(12,2) NULL,
    FreeSpaceInFileGB decimal(12,2) NULL,
    PRIMARY KEY (DatabaseID, FileID)
);

DECLARE @DatabaseName sysname;
DECLARE @Sql nvarchar(max);
DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR
SELECT name
FROM sys.databases
WHERE state_desc = N'ONLINE';

OPEN DatabaseCursor;
FETCH NEXT FROM DatabaseCursor INTO @DatabaseName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Sql = N'
USE ' + QUOTENAME(@DatabaseName) + N';
INSERT #MI_File_Stats
(
    DatabaseID, FileID, DatabaseName, LogicalName, FileType,
    FileSizeGB, SpaceUsedGB, FreeSpaceInFileGB
)
SELECT
    DB_ID(), file_id, DB_NAME(), name, type_desc,
    CAST(size * 8.0 / 1024.0 / 1024.0 AS decimal(12,2)),
    CAST(
        CASE WHEN type_desc = ''LOG''
             THEN ISNULL((SELECT used_log_space_in_bytes * 1.0 / NULLIF(total_log_size_in_bytes,0) FROM sys.dm_db_log_space_usage) * size, 0)
             ELSE ISNULL(FILEPROPERTY(name, ''SpaceUsed''), 0) END
        * 8.0 / 1024.0 / 1024.0 AS decimal(12,2)),
    CAST(
        (size - CASE WHEN type_desc = ''LOG''
                     THEN ISNULL((SELECT used_log_space_in_bytes * 1.0 / NULLIF(total_log_size_in_bytes,0) FROM sys.dm_db_log_space_usage) * size, 0)
                     ELSE ISNULL(FILEPROPERTY(name, ''SpaceUsed''), 0) END)
        * 8.0 / 1024.0 / 1024.0 AS decimal(12,2))
FROM sys.database_files;';

    BEGIN TRY
        EXEC sys.sp_executesql @Sql;
    END TRY
    BEGIN CATCH
        PRINT CONCAT('Metadata skipped for ', QUOTENAME(@DatabaseName), ': ', ERROR_MESSAGE());
    END CATCH;

    FETCH NEXT FROM DatabaseCursor INTO @DatabaseName;
END;
CLOSE DatabaseCursor;
DEALLOCATE DatabaseCursor;

-- Classic General Purpose instance ceiling: the sum of every file's own limit,
-- tempdb left out. It needs every file's size; if any database's metadata was
-- skipped, the ceiling stays unknown rather than being taken from a partial sum.
DECLARE @FilesWithoutMetadata int =
(
    SELECT COUNT(*)
    FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS v
    WHERE v.database_id <> 2
      AND v.database_id IN (SELECT database_id FROM sys.databases WHERE state_desc = N'ONLINE')
      AND NOT EXISTS (SELECT 1 FROM #MI_File_Stats AS f WHERE f.DatabaseID = v.database_id AND f.FileID = v.file_id)
);

UPDATE ic
SET MaxInstanceIOPS = s.SumIOPS,
    MaxInstanceThroughputMBps = CAST(s.SumMiBps * 1.048576 AS decimal(19,2)),
    InstanceCeilingBasis = CONCAT(N'Classic General Purpose: sum of the limits of ', s.FileCount,
                                  N' data and log files, tempdb excluded (', s.SumIOPS, N' IOPS, ', s.SumMiBps,
                                  N' MiB/s). Reached only if the workload uses all files; automatic backups use some IOPS.')
FROM #Instance_Config AS ic
CROSS APPLY
(
    SELECT COUNT(*) AS FileCount, SUM(lim.FileIOPS) AS SumIOPS, SUM(lim.FileMiBps) AS SumMiBps
    FROM #MI_File_Stats AS f
    CROSS APPLY (SELECT TOP (1) FileIOPS, FileMiBps FROM #GP_File_Limits
                 WHERE f.FileSizeGB <= MaxFileSizeGiB ORDER BY BracketOrder) AS lim
    WHERE f.DatabaseID <> 2
) AS s
WHERE ic.StorageModel = 'classic' AND @FilesWithoutMetadata = 0 AND s.FileCount > 0;

UPDATE #Instance_Config
SET LimitsNote = LimitsNote + CONCAT(N'Classic instance ceiling unknown: the size of ', @FilesWithoutMetadata,
                                     N' file(s) could not be read (see the Messages tab). A partial sum is not used. ')
WHERE StorageModel = 'classic' AND MaxInstanceIOPS IS NULL;

/* STEP 3: FIVE-SECOND INSTANCE-WIDE I/O SNAPSHOT */
CREATE TABLE #File_IO_Snapshot_1
(
    database_id int, file_id int,
    num_of_reads bigint, num_of_writes bigint,
    num_of_bytes_read bigint, num_of_bytes_written bigint,
    io_stall_read_ms bigint, io_stall_write_ms bigint,
    io_stall bigint, sample_ms bigint,
    PRIMARY KEY (database_id, file_id)
);
CREATE TABLE #File_IO_Snapshot_2
(
    database_id int, file_id int,
    num_of_reads bigint, num_of_writes bigint,
    num_of_bytes_read bigint, num_of_bytes_written bigint,
    io_stall_read_ms bigint, io_stall_write_ms bigint,
    io_stall bigint, sample_ms bigint,
    PRIMARY KEY (database_id, file_id)
);

INSERT #File_IO_Snapshot_1
SELECT database_id, file_id, num_of_reads, num_of_writes,
       num_of_bytes_read, num_of_bytes_written,
       io_stall_read_ms, io_stall_write_ms, io_stall, sample_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL);

WAITFOR DELAY '00:00:05';

INSERT #File_IO_Snapshot_2
SELECT database_id, file_id, num_of_reads, num_of_writes,
       num_of_bytes_read, num_of_bytes_written,
       io_stall_read_ms, io_stall_write_ms, io_stall, sample_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL);

/* STEP 4: DELTAS AND LIVE METRICS */
CREATE TABLE #FileDeltas
(
    database_id int NOT NULL,
    file_id int NOT NULL,
    Sample_Seconds decimal(19,3),
    Reads_Delta bigint, Writes_Delta bigint,
    Bytes_Read_Delta bigint, Bytes_Written_Delta bigint,
    Read_Stall_Delta_MS bigint, Write_Stall_Delta_MS bigint,
    IO_Stall_Delta_MS bigint,
    Read_IOPS decimal(19,2), Write_IOPS decimal(19,2), Live_File_IOPS decimal(19,2),
    Live_Read_MiBps decimal(19,2), Live_Write_MiBps decimal(19,2),
    Live_Avg_Read_Latency_MS decimal(19,2), Live_Avg_Write_Latency_MS decimal(19,2),
    Live_Avg_Stall_Per_IO_MS decimal(19,2),
    PRIMARY KEY (database_id, file_id)
);

;WITH DeltaSource AS
(
    SELECT
        s1.database_id, s1.file_id,
        (s2.sample_ms - s1.sample_ms) / 1000.0 AS Sample_Seconds,
        s2.num_of_reads - s1.num_of_reads AS Reads_Delta,
        s2.num_of_writes - s1.num_of_writes AS Writes_Delta,
        s2.num_of_bytes_read - s1.num_of_bytes_read AS Bytes_Read_Delta,
        s2.num_of_bytes_written - s1.num_of_bytes_written AS Bytes_Written_Delta,
        s2.io_stall_read_ms - s1.io_stall_read_ms AS Read_Stall_Delta_MS,
        s2.io_stall_write_ms - s1.io_stall_write_ms AS Write_Stall_Delta_MS,
        s2.io_stall - s1.io_stall AS IO_Stall_Delta_MS
    FROM #File_IO_Snapshot_1 AS s1
    JOIN #File_IO_Snapshot_2 AS s2
      ON s2.database_id = s1.database_id AND s2.file_id = s1.file_id
)
INSERT #FileDeltas
SELECT
    database_id, file_id,
    CAST(Sample_Seconds AS decimal(19,3)),
    Reads_Delta, Writes_Delta, Bytes_Read_Delta, Bytes_Written_Delta,
    Read_Stall_Delta_MS, Write_Stall_Delta_MS, IO_Stall_Delta_MS,
    CAST(Reads_Delta / NULLIF(Sample_Seconds,0) AS decimal(19,2)),
    CAST(Writes_Delta / NULLIF(Sample_Seconds,0) AS decimal(19,2)),
    CAST((Reads_Delta + Writes_Delta) / NULLIF(Sample_Seconds,0) AS decimal(19,2)),
    CAST(Bytes_Read_Delta / 1048576.0 / NULLIF(Sample_Seconds,0) AS decimal(19,2)),
    CAST(Bytes_Written_Delta / 1048576.0 / NULLIF(Sample_Seconds,0) AS decimal(19,2)),
    CAST(ISNULL(Read_Stall_Delta_MS * 1.0 / NULLIF(Reads_Delta,0),0) AS decimal(19,2)),
    CAST(ISNULL(Write_Stall_Delta_MS * 1.0 / NULLIF(Writes_Delta,0),0) AS decimal(19,2)),
    CAST(ISNULL(IO_Stall_Delta_MS * 1.0 / NULLIF(Reads_Delta + Writes_Delta,0),0) AS decimal(19,2))
FROM DeltaSource;

DECLARE @StorageModel varchar(20) = (SELECT TOP (1) StorageModel FROM #Instance_Config);

-- Keep sampled files even when their database's metadata could not be read.
INSERT INTO #MI_File_Stats
(
    DatabaseID, FileID, DatabaseName, LogicalName, FileType,
    FileSizeGB, SpaceUsedGB, FreeSpaceInFileGB
)
SELECT
    d.database_id, d.file_id, db.name, CONCAT(N'file ', d.file_id),
    NULL, NULL, NULL, NULL
FROM #FileDeltas AS d
JOIN sys.databases AS db ON db.database_id = d.database_id AND db.state_desc = N'ONLINE'
LEFT JOIN #MI_File_Stats AS f ON f.DatabaseID = d.database_id AND f.FileID = d.file_id
WHERE f.FileID IS NULL;

DECLARE @FilesWithMissingDetails int = @@ROWCOUNT;

UPDATE #Instance_Config
SET LimitsNote = LimitsNote + CONCAT(N'Metadata could not be read for ', @FilesWithMissingDetails,
                                     N' sampled file(s). Their I/O is retained under file IDs; names, types, and sizes are unknown. ')
WHERE @FilesWithMissingDetails > 0;

-- This also catches files first observed after the metadata/ceiling capture.
UPDATE #Instance_Config
SET MaxInstanceIOPS = NULL,
    MaxInstanceThroughputMBps = NULL,
    InstanceCeilingBasis = NULL,
    LimitsNote = LimitsNote + N'Classic instance ceiling unknown: sampled files have no recorded size. A partial sum is not used. '
WHERE StorageModel = 'classic'
  AND EXISTS (SELECT 1 FROM #MI_File_Stats WHERE DatabaseID <> 2 AND FileSizeGB IS NULL);

-- Instance totals count what the instance limit counts: tempdb is left out on
-- General Purpose (local SSD) and included on Business Critical.
DECLARE @CombinedLiveInstanceIOPS decimal(19,2) =
    (SELECT ISNULL(SUM(d.Live_File_IOPS),0)
     FROM #FileDeltas AS d
     WHERE d.database_id IN (SELECT database_id FROM sys.databases WHERE state_desc = N'ONLINE')
       AND (@StorageModel = 'business-critical' OR d.database_id <> 2));
DECLARE @CombinedLiveInstanceMBps decimal(19,2) =
    (SELECT ISNULL(SUM((d.Bytes_Read_Delta + d.Bytes_Written_Delta) / 1000000.0 / NULLIF(d.Sample_Seconds,0)),0)
     FROM #FileDeltas AS d
     WHERE d.database_id IN (SELECT database_id FROM sys.databases WHERE state_desc = N'ONLINE')
       AND (@StorageModel = 'business-critical' OR d.database_id <> 2));
-- Every online database's I/O, tempdb included: the base for result set 3's shares.
DECLARE @AllObservedIOPS decimal(19,2) =
    (SELECT ISNULL(SUM(d.Live_File_IOPS),0)
     FROM #FileDeltas AS d
     WHERE d.database_id IN (SELECT database_id FROM sys.databases WHERE state_desc = N'ONLINE'));
DECLARE @ObservedInstanceLogWriteMiBps decimal(19,2) =
    CASE WHEN EXISTS
         (SELECT 1 FROM #MI_File_Stats AS f
          JOIN #FileDeltas AS d ON d.database_id = f.DatabaseID AND d.file_id = f.FileID
          WHERE f.FileType IS NULL AND (d.Reads_Delta > 0 OR d.Writes_Delta > 0))
         THEN NULL
         ELSE
             (SELECT ISNULL(SUM(CASE WHEN f.FileType = 'LOG' THEN d.Live_Write_MiBps ELSE 0 END),0)
              FROM #MI_File_Stats AS f
              LEFT JOIN #FileDeltas AS d ON d.database_id=f.DatabaseID AND d.file_id=f.FileID)
    END;

UPDATE #Instance_Config
SET LimitsNote = LimitsNote + N'Instance log write rate unknown: an active file has no recorded type. A partial log write rate is not used. '
WHERE @ObservedInstanceLogWriteMiBps IS NULL;

DECLARE @MaxInstanceIOPS decimal(19,2) = (SELECT TOP (1) MaxInstanceIOPS FROM #Instance_Config);
DECLARE @MaxInstanceThroughputMBps decimal(19,2) = (SELECT TOP (1) MaxInstanceThroughputMBps FROM #Instance_Config);
DECLARE @EstimatedInstanceLogCeiling decimal(19,2) =
    (SELECT TOP (1) EstimatedInstanceLogWriteCeilingMiBps FROM #Instance_Config);
DECLARE @InstanceIOPSUtilization decimal(9,2) =
    100.0 * @CombinedLiveInstanceIOPS / NULLIF(@MaxInstanceIOPS,0);
DECLARE @InstanceThroughputUtilization decimal(9,2) =
    100.0 * @CombinedLiveInstanceMBps / NULLIF(@MaxInstanceThroughputMBps,0);
DECLARE @InstanceLogUtilization decimal(9,2) =
    100.0 * @ObservedInstanceLogWriteMiBps / NULLIF(@EstimatedInstanceLogCeiling,0);
DECLARE @InstancePressure bit =
    IIF(ISNULL(@InstanceIOPSUtilization,0) >= 70
        OR ISNULL(@InstanceThroughputUtilization,0) >= 70
        OR ISNULL(@InstanceLogUtilization,0) >= 70, 1, 0);
-- Storage limits judged: the tier is known and, on classic, the instance ceiling too.
DECLARE @StorageLimitsKnown bit =
    IIF(@StorageModel IS NOT NULL AND (@StorageModel <> 'classic' OR @MaxInstanceIOPS IS NOT NULL)
        AND @FilesWithMissingDetails = 0, 1, 0);

/* Build reusable file analysis. Per-file limits apply only on classic General
   Purpose, to data and log files, not tempdb. */
SELECT
    f.*,
    CAST(IIF(@StorageModel = 'classic' AND f.DatabaseID <> 2, 1, 0) AS bit) AS FileLimitApplies,
    CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN lim.FileIOPS END AS EstimatedFileIOPSCeiling,
    CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN lim.FileMiBps END AS EstimatedFileThroughputCeilingMiBps,
    CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN nxt.MinSizeGiB END AS NextStepFileSizeGiB,
    CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN nxt.FileIOPS END AS NextStepFileIOPS,
    CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN nxt.FileMiBps END AS NextStepFileMiBps,
    -- Microsoft gives 22-65 MiB/s per database by log file size, but not the
    -- cut-offs. These cut-offs are this script's estimate.
    CASE WHEN f.FileType = 'LOG' AND @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN
        CASE WHEN f.FileSizeGB <= 128 THEN 22 WHEN f.FileSizeGB <= 512 THEN 30
             WHEN f.FileSizeGB <= 1024 THEN 50 ELSE 65 END END AS EstimatedDatabaseLogCapMBps,
    ISNULL(d.Sample_Seconds,0) AS Sample_Seconds,
    ISNULL(d.Read_IOPS,0) AS Read_IOPS,
    ISNULL(d.Write_IOPS,0) AS Write_IOPS,
    ISNULL(d.Live_File_IOPS,0) AS Live_File_IOPS,
    ISNULL(d.Live_Read_MiBps,0) AS Live_Read_MiBps,
    ISNULL(d.Live_Write_MiBps,0) AS Live_Write_MiBps,
    ISNULL(d.Live_Avg_Read_Latency_MS,0) AS Live_Avg_Read_Latency_MS,
    ISNULL(d.Live_Avg_Write_Latency_MS,0) AS Live_Avg_Write_Latency_MS,
    ISNULL(d.IO_Stall_Delta_MS,0) AS IO_Stall_Delta_MS,
    ISNULL(d.Live_Avg_Stall_Per_IO_MS,0) AS Live_Avg_Stall_Per_IO_MS,
    CAST(CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN
         100.0 * ISNULL(d.Live_File_IOPS,0) / NULLIF(lim.FileIOPS,0) END AS decimal(9,2)) AS EstimatedFileIOPSUtilizationPercent,
    CAST(CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN
         100.0 * (ISNULL(d.Live_Read_MiBps,0) + ISNULL(d.Live_Write_MiBps,0)) / NULLIF(lim.FileMiBps,0) END AS decimal(9,2))
        AS EstimatedFileThroughputUtilizationPercent,
    -- The greater of the two per-file percentages decides whether a file is near its limit.
    CAST(CASE WHEN @StorageModel = 'classic' AND f.DatabaseID <> 2 THEN
         (SELECT MAX(pct) FROM (VALUES
             (100.0 * ISNULL(d.Live_File_IOPS,0) / NULLIF(lim.FileIOPS,0)),
             (100.0 * (ISNULL(d.Live_Read_MiBps,0) + ISNULL(d.Live_Write_MiBps,0)) / NULLIF(lim.FileMiBps,0))) AS u(pct))
         END AS decimal(9,2)) AS EstimatedFileUtilizationPercent
INTO #FileAnalysis
FROM #MI_File_Stats AS f
LEFT JOIN #FileDeltas AS d ON d.database_id=f.DatabaseID AND d.file_id=f.FileID
OUTER APPLY (SELECT TOP (1) BracketOrder, FileIOPS, FileMiBps FROM #GP_File_Limits
             WHERE f.FileSizeGB <= MaxFileSizeGiB ORDER BY BracketOrder) AS lim
-- The next size step that raises this file's limit, if there is one: one GiB
-- above the top of the current bracket (Microsoft's brackets are "> N and <= M").
OUTER APPLY (SELECT TOP (1) CAST(cur.MaxFileSizeGiB + 1 AS int) AS MinSizeGiB, n.FileIOPS, n.FileMiBps
             FROM #GP_File_Limits AS n
             JOIN #GP_File_Limits AS cur ON cur.BracketOrder = lim.BracketOrder
             WHERE n.BracketOrder = lim.BracketOrder + 1 AND n.FileIOPS > cur.FileIOPS) AS nxt;

/* RESULT SET 1: DETAILED FILE PROFILE AND GUIDANCE */
SELECT
    DatabaseName, LogicalName, FileType,
    FileSizeGB AS Current_File_Size_GiB,
    SpaceUsedGB AS Space_Used_Inside_File_GiB,
    FreeSpaceInFileGB AS Free_Space_Inside_File_GiB,
    CASE
        WHEN DatabaseID = 2 AND @StorageModel IN ('classic', 'next-gen') THEN 'Local SSD (tempdb): outside the storage limits'
        WHEN @StorageModel = 'business-critical' THEN CAST(CAST(ic.MaxInstanceIOPS AS int) AS varchar(30)) + ' IOPS (Pooled BC Total)'
        WHEN @StorageModel = 'next-gen' THEN CAST(CAST(ic.MaxInstanceIOPS AS int) AS varchar(30)) + ' IOPS (Pooled Next-gen Total)'
        WHEN @StorageModel = 'classic' THEN
            CAST(EstimatedFileIOPSCeiling AS varchar(10)) + ' IOPS / ' + CAST(EstimatedFileThroughputCeilingMiBps AS varchar(10)) + ' MiB/s per file'
            + CASE WHEN FileType = 'LOG'
                   THEN '; database log ~' + CAST(EstimatedDatabaseLogCapMBps AS varchar(10)) + ' MiB/s (estimated within Microsoft''s 22-65 range)'
                   ELSE '' END
        ELSE 'Not judged: set @GeneralPurposeStorage'
    END AS Estimated_File_Max_IOPS_Or_Log_Cap,
    Live_File_IOPS AS Live_Current_File_IOPS,
    IO_Stall_Delta_MS AS Live_IO_Stall_Window_Delta_MS,
    Live_Avg_Stall_Per_IO_MS,
    CASE
        WHEN FileLimitApplies = 1 AND EstimatedFileUtilizationPercent >= 70
             AND (Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15)
             AND @InstancePressure = 0 THEN
            'CRITICAL LATENCY: This file is near its own limit and slow; expect '
            + IIF(FileType = 'LOG', 'WRITELOG', 'PAGEIOLATCH') + ' waits (confirm in wait stats). '
            + CASE
                WHEN NextStepFileSizeGiB IS NOT NULL THEN
                    'Action to evaluate: grow the file to ' + CAST(NextStepFileSizeGiB AS varchar(10)) + ' GiB to raise its limit from '
                    + CAST(EstimatedFileIOPSCeiling AS varchar(10)) + ' to ' + CAST(NextStepFileIOPS AS varchar(10)) + ' IOPS and from '
                    + CAST(EstimatedFileThroughputCeilingMiBps AS varchar(10)) + ' to ' + CAST(NextStepFileMiBps AS varchar(10)) + ' MiB/s.'
                    + IIF(FileType = 'LOG', ' The database or instance log write limit may still bind first.', '')
                ELSE 'This file is at the largest per-file limit (7,500 IOPS, 250 MiB/s); a larger file will not raise it. '
                   + 'Spreading the data across more files raises the instance total, and Next-gen General Purpose pools IOPS for the instance. '
                   + 'More vCores do not raise a classic General Purpose file limit.'
              END
        WHEN @StorageLimitsKnown = 0 THEN 'Not judged: storage limits are unknown (see Limits_Note in result set 2).'
        ELSE 'Healthy Storage Subsystem'
    END AS Diagnostic_Action_Item,
    CASE
        WHEN FileLimitApplies = 1 AND EstimatedFileUtilizationPercent >= 70
             AND (Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15)
             AND @InstancePressure = 0 AND NextStepFileSizeGiB IS NOT NULL THEN
            '-- ALTER DATABASE ' + QUOTENAME(DatabaseName) + ' MODIFY FILE (NAME = N''' + REPLACE(LogicalName,'''','''''')
            + ''', SIZE = ' + CAST(NextStepFileSizeGiB AS varchar(10)) + 'GB);  -- SQL Server GB = GiB; review before running'
        WHEN FileLimitApplies = 1 AND EstimatedFileUtilizationPercent >= 70
             AND (Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15)
             AND @InstancePressure = 0 THEN '-- No larger size raises this file''s limit.'
        WHEN @StorageLimitsKnown = 0 THEN '-- File metadata or storage limits are unknown; no resize statement generated.'
        ELSE '-- File performance is healthy.'
    END AS Safety_Script_To_Expand_File,
    CASE
        WHEN @StorageModel <> 'classic' OR @StorageModel IS NULL THEN 'N/A (Not classic General Purpose, or storage type not set)'
        WHEN @InstancePressure = 1
          OR (FileLimitApplies = 1 AND NextStepFileSizeGiB IS NULL AND EstimatedFileUtilizationPercent >= 70)
            THEN 'RECOMMEND EVALUATION: ' + @NextGenSpec
        ELSE 'No immediate need; classic GP remediation (file expansion) remains available.'
    END AS Next_Gen_GP_Recommendation,
    Sample_Seconds, Read_IOPS, Write_IOPS, Live_File_IOPS,
    Live_Read_MiBps, Live_Write_MiBps,
    Live_Avg_Read_Latency_MS, Live_Avg_Write_Latency_MS,
    EstimatedFileIOPSUtilizationPercent,
    EstimatedFileThroughputUtilizationPercent,
    @InstanceIOPSUtilization AS Estimated_Instance_IOPS_Utilization_Percent,
    CASE
        WHEN FileLimitApplies = 1 AND EstimatedFileUtilizationPercent >= 70
             AND (Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15)
             AND @InstancePressure = 0 THEN 'FILE_LEVEL'
        WHEN @InstancePressure = 1 THEN 'INSTANCE_LEVEL'
        WHEN Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15 THEN 'NOT_PROVEN'
        WHEN @StorageLimitsKnown = 0 THEN 'NOT_ASSESSED'
        ELSE 'HEALTHY_OR_NO_ACTIVITY'
    END AS Constraint_Classification,
    CASE
        WHEN @InstancePressure = 1
            THEN 'File expansion is unlikely to resolve the primary constraint. Evaluate MI capacity/configuration.'
        WHEN Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15
            THEN 'Elevated latency is present, but file/instance ceiling proximity is not proven. Investigate waits and repeat the sample before resizing.'
        WHEN @StorageLimitsKnown = 0
            THEN 'Storage limits were not judged; see Limits_Note in result set 2.'
        ELSE 'No additional file or instance capacity constraint is proven in this sample.'
    END AS Merged_Recommendation
FROM #FileAnalysis
CROSS JOIN #Instance_Config AS ic
ORDER BY DatabaseName, FileType DESC, LogicalName;

/* RESULT SET 2: INSTANCE CAPACITY AND OVERLOAD DIAGNOSIS */
SELECT
    ic.ServiceTier AS Service_Tier,
    ic.StorageModel AS Storage_Model,
    ic.HardwareGeneration AS Hardware_Generation,
    ic.vCores AS Allocated_vCores,
    ic.MaxInstanceIOPS AS Max_Instance_IOPS_Ceiling,
    @CombinedLiveInstanceIOPS AS Live_Total_Instance_Driven_IOPS,
    CASE
        WHEN @InstanceIOPSUtilization IS NULL THEN 'Not judged: ' + ic.LimitsNote
        WHEN @InstanceIOPSUtilization >= 90 THEN
            'CRITICAL OVERLOAD: Instance is driving ' + CAST(CAST(@CombinedLiveInstanceIOPS AS int) AS varchar(10))
            + ' IOPS, 90% or more of its ' + CAST(CAST(ic.MaxInstanceIOPS AS int) AS varchar(10)) + ' IOPS ceiling. '
            + CASE ic.StorageModel
                WHEN 'classic' THEN 'This ceiling is the sum of the files'' limits: larger files (up to 1,025 GiB each) or more files raise it; more vCores do not.'
                WHEN 'next-gen' THEN 'Raise the provisioned IOPS up to the vCore cap, or add vCores to raise the cap.'
                ELSE 'Add vCores (4,000 IOPS each, up to 320,000).'
              END
        WHEN @InstanceIOPSUtilization >= 70 THEN 'WARNING: High storage volume traffic. Consuming over 70% of the instance IOPS ceiling. Monitor closely.'
        ELSE 'Healthy: Combined instance storage workload is well within the instance IOPS ceiling.'
    END AS Instance_IOPS_Alert_Status,
    ic.MaxInstanceThroughputMBps AS Max_Instance_Throughput_MBps,
    @CombinedLiveInstanceMBps AS Live_Total_Instance_MBps,
    @InstanceThroughputUtilization AS Estimated_Instance_Throughput_Utilization_Percent,
    ic.InstanceCeilingBasis AS Instance_Ceiling_Basis,
    ic.TotalInstanceReservedGB AS Total_Volume_Size_GB,
    ic.TotalInstanceReservedGB-ic.TotalInstanceUsedGB AS Volume_Free_Space_GB,
    CAST(ic.EstimatedInstanceLogWriteCeilingMiBps AS varchar(20)) + ' MiB/s' AS Instance_Log_Write_Ceiling,
    CASE
        WHEN ic.StorageModel IS NULL OR ic.StorageModel <> 'classic' THEN 'N/A (Not classic General Purpose, or storage type not set)'
        WHEN ic.TotalInstanceReservedGB-ic.TotalInstanceUsedGB < ic.TotalInstanceReservedGB*0.10
          OR @InstancePressure = 1
          OR EXISTS (SELECT 1 FROM #FileAnalysis WHERE FileLimitApplies = 1 AND NextStepFileSizeGiB IS NULL)
        THEN 'RECOMMEND EVALUATION: '+@NextGenSpec
        ELSE 'No immediate need; classic GP remediation (file expansion) remains available.'
    END AS Next_Gen_GP_Recommendation,
    @InstanceIOPSUtilization AS Estimated_Instance_IOPS_Utilization_Percent,
    ic.TotalInstanceUsedGB AS Total_Volume_Used_GB,
    @ObservedInstanceLogWriteMiBps AS Observed_Instance_Log_Write_MiBps,
    @InstanceLogUtilization AS Estimated_Instance_Log_Utilization_Percent,
    CASE
        WHEN @InstancePressure = 1 AND EXISTS
             (SELECT 1 FROM #FileAnalysis WHERE FileLimitApplies = 1 AND EstimatedFileUtilizationPercent>=70) THEN 'MIXED'
        WHEN @InstancePressure = 1 THEN 'INSTANCE_LEVEL'
        WHEN EXISTS (SELECT 1 FROM #FileAnalysis WHERE FileLimitApplies = 1 AND EstimatedFileUtilizationPercent>=70
                     AND (Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15)) THEN 'FILE_LEVEL'
        WHEN @StorageLimitsKnown = 0 THEN 'NOT_ASSESSED'
        ELSE 'NOT_PROVEN'
    END AS Capacity_Constraint_Classification,
    CASE
        WHEN ISNULL(@InstanceLogUtilization,0)>=70 THEN
            'Observed log write throughput is near the instance ceiling. Correlate with WRITELOG and INSTANCE_LOG_RATE_GOVERNOR; additional ADF writers may not help.'
        WHEN ISNULL(@InstanceIOPSUtilization,0)>=70 OR ISNULL(@InstanceThroughputUtilization,0)>=70 THEN
            'Observed I/O is near the instance ceiling. Single-file expansion is unlikely to resolve an instance-wide limit.'
        WHEN EXISTS (SELECT 1 FROM #FileAnalysis WHERE FileLimitApplies = 1 AND EstimatedFileUtilizationPercent>=70
                     AND (Live_Avg_Read_Latency_MS>15 OR Live_Avg_Write_Latency_MS>15)) THEN
            'Instance has headroom but one or more files show high latency near their own limit. Evaluate file-level remediation (result set 1).'
        WHEN @StorageLimitsKnown = 0 THEN
            'Storage limits were not judged; see Limits_Note. Waits (WRITELOG, INSTANCE_LOG_RATE_GOVERNOR, PAGEIOLATCH) are still the proof of a limit.'
        ELSE 'This sample does not prove a file-size or instance-capacity constraint. Correlate with waits and repeat during sustained load.'
    END AS Evidence_Based_Next_Action,
    NULLIF(ic.LimitsNote, N'') AS Limits_Note,
    @LimitsSource AS Limits_Source
FROM #Instance_Config AS ic;

/* RESULT SET 3: DATABASE ACTIVITY BREAKDOWN */
;WITH DatabaseActivity AS
(
    SELECT
        DatabaseID, DatabaseName,
        CASE WHEN DatabaseID=@TargetDatabaseID THEN 1
             WHEN DatabaseName='tempdb' THEN 2
             WHEN DatabaseID>4 THEN 3 ELSE 4 END AS DisplayOrder,
        CASE WHEN DatabaseID<=4 THEN 1 ELSE 0 END AS IsSystemDatabase,
        SUM(Read_IOPS) AS Read_IOPS,
        SUM(Write_IOPS) AS Write_IOPS,
        SUM(Live_File_IOPS) AS Total_IOPS,
        SUM(Live_Read_MiBps) AS Read_MiBps,
        SUM(Live_Write_MiBps) AS Write_MiBps,
        CASE WHEN MAX(CASE WHEN FileType IS NULL AND Live_File_IOPS > 0 THEN 1 ELSE 0 END) = 1
             THEN NULL
             ELSE SUM(CASE WHEN FileType='LOG' THEN Live_Write_MiBps ELSE 0 END)
        END AS Log_Write_MiBps
    FROM #FileAnalysis
    GROUP BY DatabaseID, DatabaseName
)
SELECT
    DatabaseName,
    CAST(IIF(DatabaseID = @TargetDatabaseID, 1, 0) AS bit) AS Is_Target_Database,
    CAST(Read_IOPS AS decimal(19,2)) AS Read_IOPS,
    CAST(Write_IOPS AS decimal(19,2)) AS Write_IOPS,
    CAST(Total_IOPS AS decimal(19,2)) AS Total_IOPS,
    CAST(Read_MiBps AS decimal(19,2)) AS Read_MiBps,
    CAST(Write_MiBps AS decimal(19,2)) AS Write_MiBps,
    CAST(Log_Write_MiBps AS decimal(19,2)) AS Log_Write_MiBps,
    CAST(ISNULL(100.0*Total_IOPS/NULLIF(@AllObservedIOPS,0),0) AS decimal(9,2)) AS Percent_Of_Observed_Instance_IOPS
FROM DatabaseActivity
ORDER BY Total_IOPS DESC;

DROP TABLE #FileAnalysis;
DROP TABLE #FileDeltas;
DROP TABLE #File_IO_Snapshot_2;
DROP TABLE #File_IO_Snapshot_1;
DROP TABLE #MI_File_Stats;
DROP TABLE #Instance_Config;
DROP TABLE #NextGen_VCore_Limits;
DROP TABLE #GP_File_Limits;
