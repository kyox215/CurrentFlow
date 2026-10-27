"""Generate labelled, isolated synthetic history for native UI verification only."""
import math
import sqlite3
import sys
import time
from pathlib import Path

path = Path(sys.argv[1]).resolve()
if not str(path).startswith('/private/tmp/currentflow-'):
    raise SystemExit('Demo fixture must be in a /private/tmp/currentflow-* directory')
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    raise SystemExit('Refusing to overwrite an existing database')
now = int(time.time())
c = sqlite3.connect(path)
c.execute('''CREATE TABLE samples(second INTEGER PRIMARY KEY, observed REAL NOT NULL, watts REAL,
 cpu REAL,gpu REAL,display REAL,input REAL,battery REAL,external INTEGER NOT NULL,flow TEXT NOT NULL,
 estimated INTEGER NOT NULL,source TEXT NOT NULL,sensor_time REAL,session TEXT NOT NULL,
 energy_wh REAL NOT NULL,duration REAL NOT NULL)''')

def rows():
    previous = None
    for second in range(now - 604799, now + 1):
        age = now - second
        if 1500 <= age <= 1850 or 55000 <= age <= 86000:
            previous = None
            continue
        wave = 19 + 5 * math.sin(second / 430) + 3 * math.sin(second / 51)
        workload = 28 * math.exp(-((age % 7200 - 2750) / 400) ** 2)
        watts = max(2, wave + workload + 0.8 * math.sin(second * 1.7))
        valid = second % 1201 != 0
        external = (age // 10000) % 3 != 1
        duration = 1 if previous and previous[0] == second - 1 and valid else 0
        energy = (previous[1] + watts) * 0.5 / 3600 if duration else 0
        previous = (second, watts) if valid else None
        yield (second, second + 0.1, watts if valid else None,
               watts * (0.28 + 0.1 * math.sin(second / 67)), watts * 0.07, 2.4,
               watts + 10 if external else 0, 10 if external else -watts, int(external),
               'charging' if external else 'discharging', int(second % 601 < 25),
               'systemCache' if second % 601 < 25 else 'sensor', second + 0.1,
               'SYNTHETIC-DEMO-ONLY', energy, duration)

c.executemany('INSERT INTO samples VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', rows())
c.commit()
print('Synthetic demo rows:', c.execute('SELECT COUNT(*) FROM samples').fetchone()[0])
c.close()
