#!/usr/bin/env bash
# Writes Demo/demo.sqlite, the database of the screenshot in the README.
#
# The file is committed, so this runs only when the demo itself should change.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p Demo
rm -f Demo/demo.sqlite

sqlite3 Demo/demo.sqlite <<'SQL'
CREATE TABLE plant (
  slug        TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  city        TEXT NOT NULL,
  silo_count  INTEGER NOT NULL
);

CREATE TABLE delivery (
  id                 INTEGER PRIMARY KEY,
  slug               TEXT NOT NULL,
  plant_slug         TEXT NOT NULL REFERENCES plant(slug),
  recipe             TEXT NOT NULL,
  started_at         TEXT NOT NULL,
  volume_cubic_meter REAL NOT NULL,
  temperature_celsius REAL,
  finalized          INTEGER NOT NULL,
  batches            TEXT
);

CREATE VIEW delivery_by_plant AS
SELECT plant_slug, count(*) AS deliveries, round(sum(volume_cubic_meter), 1) AS volume
FROM delivery
GROUP BY plant_slug;

INSERT INTO plant (slug, name, city, silo_count) VALUES
  ('nord', 'Werk Nord', 'Hamburg', 6),
  ('sued', 'Werk Süd', 'München', 4),
  ('ost',  'Werk Ost',  'Dresden', 5);

INSERT INTO delivery
  (id, slug, plant_slug, recipe, started_at, volume_cubic_meter, temperature_celsius,
   finalized, batches)
VALUES
  (1, 'dl-2026-0417', 'sued', 'C25/30 XC4', '2026-04-17 06:35:55', 10.0, 19.9, 1,
   '{"batches": [{"n": 1, "cement_kg": 1720, "water_l": 770}, {"n": 2, "cement_kg": 1730, "water_l": 790}], "mixer": "M1"}'),
  (2, 'dl-2026-0418', 'ost', 'C20/25 XC1', '2026-04-17 06:50:11', 10.0, 18.4, 1,
   '{"batches": [{"n": 1, "cement_kg": 1745, "water_l": 725}, {"n": 2, "cement_kg": 1665, "water_l": 770}], "mixer": "M3"}'),
  (3, 'dl-2026-0419', 'nord', 'C35/45 XD3', '2026-04-17 07:08:09', 5.5, 18.7, 1,
   '{"batches": [{"n": 1, "cement_kg": 1925, "water_l": 775}], "mixer": "M2"}'),
  (4, 'dl-2026-0420', 'sued', 'C30/37 XF2', '2026-04-17 07:29:28', 6.0, 19.0, 1,
   '{"batches": [{"n": 1, "cement_kg": 2076, "water_l": 852}], "mixer": "M1"}'),
  (5, 'dl-2026-0421', 'ost', 'C30/37 XF2', '2026-04-17 07:39:02', 7.0, 20.0, 1,
   '{"batches": [{"n": 1, "cement_kg": 1221, "water_l": 490}, {"n": 2, "cement_kg": 1204, "water_l": 525}], "mixer": "M3"}'),
  (6, 'dl-2026-0422', 'nord', 'C25/30 XC4', '2026-04-17 08:02:37', 7.0, 18.6, 1,
   '{"batches": [{"n": 1, "cement_kg": 1225, "water_l": 521}, {"n": 2, "cement_kg": 1207, "water_l": 490}], "mixer": "M2"}'),
  (7, 'dl-2026-0423', 'sued', 'C25/30 XC4', '2026-04-17 08:13:29', 7.5, 18.1, 1,
   '{"batches": [{"n": 1, "cement_kg": 1301, "water_l": 532}, {"n": 2, "cement_kg": 1267, "water_l": 562}], "mixer": "M1"}'),
  (8, 'dl-2026-0424', 'ost', 'C20/25 XC1', '2026-04-17 08:29:32', 7.5, 16.6, 1,
   '{"batches": [{"n": 1, "cement_kg": 1305, "water_l": 536}, {"n": 2, "cement_kg": 1282, "water_l": 536}], "mixer": "M3"}'),
  (9, 'dl-2026-0425', 'nord', 'C35/45 XD3', '2026-04-17 08:47:24', 5.5, 20.3, 1,
   '{"batches": [{"n": 1, "cement_kg": 1815, "water_l": 803}], "mixer": "M2"}'),
  (10, 'dl-2026-0426', 'sued', 'C30/37 XF2', '2026-04-17 09:02:59', 4.5, 18.4, 1,
   '{"batches": [{"n": 1, "cement_kg": 1539, "water_l": 688}], "mixer": "M1"}'),
  (11, 'dl-2026-0427', 'ost', 'C30/37 XF2', '2026-04-17 09:13:36', 7.0, 19.6, 1,
   '{"batches": [{"n": 1, "cement_kg": 1183, "water_l": 525}, {"n": 2, "cement_kg": 1162, "water_l": 521}], "mixer": "M3"}'),
  (12, 'dl-2026-0428', 'nord', 'C25/30 XC4', '2026-04-17 09:32:00', 8.5, 19.5, 1,
   '{"batches": [{"n": 1, "cement_kg": 1415, "water_l": 612}, {"n": 2, "cement_kg": 1432, "water_l": 607}], "mixer": "M2"}'),
  (13, 'dl-2026-0429', 'sued', 'C25/30 XC4', '2026-04-17 09:41:03', 9.0, 19.7, 1,
   '{"batches": [{"n": 1, "cement_kg": 1507, "water_l": 706}, {"n": 2, "cement_kg": 1512, "water_l": 693}], "mixer": "M1"}'),
  (14, 'dl-2026-0430', 'ost', 'C20/25 XC1', '2026-04-17 10:06:12', 6.0, 18.2, 1,
   '{"batches": [{"n": 1, "cement_kg": 2052, "water_l": 858}], "mixer": "M3"}'),
  (15, 'dl-2026-0431', 'nord', 'C35/45 XD3', '2026-04-17 10:27:26', 7.0, 16.5, 1,
   '{"batches": [{"n": 1, "cement_kg": 1218, "water_l": 521}, {"n": 2, "cement_kg": 1155, "water_l": 511}], "mixer": "M2"}'),
  (16, 'dl-2026-0432', 'sued', 'C30/37 XF2', '2026-04-17 10:41:25', 5.5, 16.7, 1,
   '{"batches": [{"n": 1, "cement_kg": 1837, "water_l": 803}], "mixer": "M1"}'),
  (17, 'dl-2026-0433', 'ost', 'C30/37 XF2', '2026-04-17 11:04:16', 4.5, NULL, 1,
   NULL),
  (18, 'dl-2026-0434', 'nord', 'C25/30 XC4', '2026-04-17 11:23:53', 7.5, 18.0, 1,
   '{"batches": [{"n": 1, "cement_kg": 1245, "water_l": 532}, {"n": 2, "cement_kg": 1260, "water_l": 592}], "mixer": "M2"}'),
  (19, 'dl-2026-0435', 'sued', 'C25/30 XC4', '2026-04-17 11:39:00', 8.0, 18.0, 1,
   '{"batches": [{"n": 1, "cement_kg": 1376, "water_l": 576}, {"n": 2, "cement_kg": 1392, "water_l": 620}], "mixer": "M1"}'),
  (20, 'dl-2026-0436', 'ost', 'C20/25 XC1', '2026-04-17 11:52:55', 8.5, 17.2, 1,
   '{"batches": [{"n": 1, "cement_kg": 1419, "water_l": 633}, {"n": 2, "cement_kg": 1432, "water_l": 675}], "mixer": "M3"}'),
  (21, 'dl-2026-0437', 'nord', 'C35/45 XD3', '2026-04-17 12:08:46', 7.0, 17.1, 1,
   '{"batches": [{"n": 1, "cement_kg": 1225, "water_l": 549}, {"n": 2, "cement_kg": 1176, "water_l": 532}], "mixer": "M2"}'),
  (22, 'dl-2026-0438', 'sued', 'C30/37 XF2', '2026-04-17 12:32:38', 5.5, 18.2, 1,
   '{"batches": [{"n": 1, "cement_kg": 1831, "water_l": 786}], "mixer": "M1"}'),
  (23, 'dl-2026-0439', 'ost', 'C30/37 XF2', '2026-04-17 12:42:32', 7.5, 17.5, 1,
   '{"batches": [{"n": 1, "cement_kg": 1282, "water_l": 555}, {"n": 2, "cement_kg": 1286, "water_l": 596}], "mixer": "M3"}'),
  (24, 'dl-2026-0440', 'nord', 'C25/30 XC4', '2026-04-17 13:06:18', 10.0, 17.2, 1,
   '{"batches": [{"n": 1, "cement_kg": 1660, "water_l": 720}, {"n": 2, "cement_kg": 1685, "water_l": 775}], "mixer": "M2"}'),
  (25, 'dl-2026-0441', 'sued', 'C25/30 XC4', '2026-04-17 13:32:41', 5.5, 17.6, 1,
   '{"batches": [{"n": 1, "cement_kg": 1848, "water_l": 770}], "mixer": "M1"}'),
  (26, 'dl-2026-0442', 'ost', 'C20/25 XC1', '2026-04-17 13:43:17', 8.5, 18.3, 1,
   '{"batches": [{"n": 1, "cement_kg": 1406, "water_l": 599}, {"n": 2, "cement_kg": 1423, "water_l": 633}], "mixer": "M3"}'),
  (27, 'dl-2026-0443', 'nord', 'C35/45 XD3', '2026-04-17 14:03:33', 6.0, 16.9, 1,
   '{"batches": [{"n": 1, "cement_kg": 2004, "water_l": 924}], "mixer": "M2"}'),
  (28, 'dl-2026-0444', 'sued', 'C30/37 XF2', '2026-04-17 14:22:42', 10.0, 18.8, 1,
   '{"batches": [{"n": 1, "cement_kg": 1670, "water_l": 790}, {"n": 2, "cement_kg": 1655, "water_l": 700}], "mixer": "M1"}'),
  (29, 'dl-2026-0445', 'ost', 'C30/37 XF2', '2026-04-17 14:46:58', 8.0, 19.3, 1,
   '{"batches": [{"n": 1, "cement_kg": 1324, "water_l": 560}, {"n": 2, "cement_kg": 1396, "water_l": 640}], "mixer": "M3"}'),
  (30, 'dl-2026-0446', 'nord', 'C25/30 XC4', '2026-04-17 14:57:30', 5.5, 19.4, 1,
   '{"batches": [{"n": 1, "cement_kg": 1870, "water_l": 792}], "mixer": "M2"}'),
  (31, 'dl-2026-0447', 'sued', 'C25/30 XC4', '2026-04-17 15:08:04', 9.0, 18.7, 1,
   '{"batches": [{"n": 1, "cement_kg": 1489, "water_l": 648}, {"n": 2, "cement_kg": 1530, "water_l": 679}], "mixer": "M1"}'),
  (32, 'dl-2026-0448', 'ost', 'C20/25 XC1', '2026-04-17 15:19:43', 9.0, 20.1, 1,
   '{"batches": [{"n": 1, "cement_kg": 1543, "water_l": 630}, {"n": 2, "cement_kg": 1552, "water_l": 711}], "mixer": "M3"}'),
  (33, 'dl-2026-0449', 'nord', 'C35/45 XD3', '2026-04-17 15:28:39', 8.5, 18.0, 1,
   '{"batches": [{"n": 1, "cement_kg": 1402, "water_l": 675}, {"n": 2, "cement_kg": 1411, "water_l": 603}], "mixer": "M2"}'),
  (34, 'dl-2026-0450', 'sued', 'C30/37 XF2', '2026-04-17 15:39:40', 5.5, 20.5, 1,
   '{"batches": [{"n": 1, "cement_kg": 1886, "water_l": 825}], "mixer": "M1"}'),
  (35, 'dl-2026-0451', 'ost', 'C30/37 XF2', '2026-04-17 16:00:59', 9.0, 18.3, 1,
   '{"batches": [{"n": 1, "cement_kg": 1561, "water_l": 639}, {"n": 2, "cement_kg": 1557, "water_l": 702}], "mixer": "M3"}'),
  (36, 'dl-2026-0452', 'nord', 'C25/30 XC4', '2026-04-17 16:09:19', 5.5, 18.4, 1,
   '{"batches": [{"n": 1, "cement_kg": 1853, "water_l": 786}], "mixer": "M2"}'),
  (37, 'dl-2026-0453', 'sued', 'C25/30 XC4', '2026-04-17 16:33:49', 9.0, 17.5, 1,
   '{"batches": [{"n": 1, "cement_kg": 1485, "water_l": 679}, {"n": 2, "cement_kg": 1525, "water_l": 648}], "mixer": "M1"}'),
  (38, 'dl-2026-0454', 'ost', 'C20/25 XC1', '2026-04-17 16:48:33', 6.0, 19.5, 1,
   '{"batches": [{"n": 1, "cement_kg": 2040, "water_l": 924}], "mixer": "M3"}'),
  (39, 'dl-2026-0455', 'nord', 'C35/45 XD3', '2026-04-17 17:12:57', 7.0, 17.8, 1,
   '{"batches": [{"n": 1, "cement_kg": 1183, "water_l": 511}, {"n": 2, "cement_kg": 1225, "water_l": 535}], "mixer": "M2"}'),
  (40, 'dl-2026-0456', 'sued', 'C30/37 XF2', '2026-04-17 17:27:56', 7.0, 18.0, 1,
   '{"batches": [{"n": 1, "cement_kg": 1218, "water_l": 525}, {"n": 2, "cement_kg": 1176, "water_l": 504}], "mixer": "M1"}'),
  (41, 'dl-2026-0457', 'ost', 'C30/37 XF2', '2026-04-17 17:40:31', 8.0, 19.8, 0,
   '{"batches": [{"n": 1, "cement_kg": 1324, "water_l": 568}, {"n": 2, "cement_kg": 1352, "water_l": 580}], "mixer": "M3"}'),
  (42, 'dl-2026-0458', 'nord', 'C25/30 XC4', '2026-04-17 17:52:28', 9.0, 17.6, 0,
   '{"batches": [{"n": 1, "cement_kg": 1512, "water_l": 688}, {"n": 2, "cement_kg": 1539, "water_l": 720}], "mixer": "M2"}'),
  (43, 'dl-2026-0459', 'sued', 'C25/30 XC4', '2026-04-17 18:17:31', 8.0, 19.4, 0,
   '{"batches": [{"n": 1, "cement_kg": 1396, "water_l": 616}, {"n": 2, "cement_kg": 1360, "water_l": 568}], "mixer": "M1"}'),
  (44, 'dl-2026-0460', 'ost', 'C20/25 XC1', '2026-04-17 18:27:17', 4.5, 19.2, 0,
   '{"batches": [{"n": 1, "cement_kg": 1521, "water_l": 711}], "mixer": "M3"}'),
  (45, 'dl-2026-0461', 'nord', 'C35/45 XD3', '2026-04-17 18:47:19', 4.5, 19.1, 0,
   '{"batches": [{"n": 1, "cement_kg": 1539, "water_l": 693}], "mixer": "M2"}');
SQL

echo "Wrote $PWD/Demo/demo.sqlite"
