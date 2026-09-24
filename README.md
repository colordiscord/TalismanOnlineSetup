# Talisman Online Server Setup (Ubuntu)

One script that turns a fresh Ubuntu VPS into a ready-to-use Talisman Online
server host. It installs everything, runs MySQL 5.7 for you, and gives you a
simple `talisman` command to import databases, start/stop the servers, read
logs, make backups and find problems.

**You do not need to know Linux.** Follow the steps below in order and copy/paste
the commands.

- Works on **Ubuntu 20.04, 22.04 and 24.04** (64-bit). Tested on 24.04.
- Safe to run again at any time. It never deletes your data unless you ask it to.

---

## What you need

| Thing | Where to get it |
|---|---|
| A VPS with Ubuntu 22.04 or 24.04, 2 GB+ RAM, 20 GB+ disk | OVH, Hetzner, Contabo, ... |
| The VPS IP address and **root** password | Email from your VPS provider |
| An SSH program to type commands | Windows 10/11: **PowerShell** or **Windows Terminal**; or [PuTTY](https://www.putty.org/) |
| A file upload program (SFTP) | [WinSCP](https://winscp.net/) or [FileZilla](https://filezilla-project.org/) |
| Your Talisman **server files** | `db_server`, `login_server`, `game_server` (+ their config files and libs) |
| Your Talisman **database dumps** | `db_account.sql`, `db_game.sql`, `db_log.sql` (`db_gmtool.sql` optional) |

---

## Step 1: Connect to your server

Open PowerShell and type (replace the IP with yours):

```bash
ssh root@123.45.67.89
```

Type `yes` if asked, then your root password. (Nothing appears on screen
while you type the password. That's normal.)

> **Some providers make you log in as `ubuntu` instead of root.** In that case,
> after logging in, type `sudo -i` to become root.

## Step 2: Run the setup

Copy/paste this line and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/colordiscord/TalismanOnlineSetup/main/talisman_setup.sh -o talisman_setup.sh && bash talisman_setup.sh
```

<details>
<summary>No internet access to GitHub? Upload the file instead</summary>

Download `talisman_setup.sh` from this repository, upload it to `/root` with
WinSCP/FileZilla, then run:

```bash
cd /root && bash talisman_setup.sh
```
</details>

It takes 3 to 10 minutes. When it ends with **SETUP COMPLETE**, it worked.
If it stops with an error, read the message: it tells you what to do. You can
always run the same command again.

## Step 3: Upload your server files

Open WinSCP/FileZilla and connect with:

- **Protocol:** SFTP
- **Host:** your server IP
- **Port:** 22
- **User:** root (and your password)

Then upload:

| What | Upload into |
|---|---|
| Server folders/programs (db, login, game) | `/root/talisman/server/` |
| Database dumps (`.sql` or `.sql.gz`) | `/root/talisman/sql/` |
| Extra `.so` library files (if you have them) | `/root/talisman/lib/` |

Got a `.zip`, `.rar` or `.7z` archive? Upload it anywhere (for example `/root`) and run:

```bash
talisman unpack /root/YourServerPack.zip
```

Check that everything was found:

```bash
talisman scan
```

## Step 4: Import the databases

```bash
talisman import
```

This imports every dump it finds into the right database, based on the file name
(`*account*` → `db_account`, `*game*` → `db_game`, `*log*` → `db_log`,
`*gmtool*` → `db_gmtool`). Databases that already contain tables are skipped,
so running it twice is safe.

If a file has an unusual name, import it by hand:

```bash
talisman import /root/talisman/sql/myfile.sql db_game
```

## Step 5: Point your server configs at the database

Your server config files contain a MySQL host, user and password. Show the correct values:

```bash
talisman passwords
```

Find which config files contain database settings:

```bash
talisman find-config
```

Edit them with `nano <file>` (save: `Ctrl+O`, Enter; exit: `Ctrl+X`):

- **Host:** `127.0.0.1` (or `localhost`; both work)
- **Port:** `3306`
- **User / Password:** from `talisman passwords`
- Anywhere the config asks for the server's **public IP**: use the IP shown by `talisman status`.

> **Shortcut:** if your configs already have a user/password written in them
> (for example `root` / `123456`), you can make MySQL accept those instead of
> editing every file:
> ```bash
> talisman db-user root 123456
> ```

## Step 6: Start the server

```bash
talisman start
```

This starts the DB server, then the login server, then the game server, in the
right order with a pause in between. Check that everything is running:

```bash
talisman status
```

That's it. The servers restart automatically if they crash, and start by
themselves after a reboot.

---

## Everyday commands

| Command | What it does |
|---|---|
| `talisman start` | Start all servers (db → login → game) |
| `talisman stop` | Stop all servers |
| `talisman restart` | Stop and start again |
| `talisman status` | What's running, which ports, server IP, last backup |
| `talisman logs game` | Live log of the game server (`db`, `login`, `mysql`, `all` also work). `Ctrl+C` to exit |
| `talisman doctor` | **Checks everything and tells you how to fix problems** |
| `talisman console game` | Run one server in the foreground to see its errors directly |
| `talisman backup` | Back up all databases now (also happens daily at 04:30) |
| `talisman restore` | List backups / restore one |
| `talisman sql db_game` | Open a MySQL prompt |
| `talisman firewall open 9000` | Open another port for players |
| `talisman autostart on\|off` | Start servers after reboot (on by default) |
| `talisman self-update` | Download the latest version of this setup and apply it |
| `talisman help` | All commands |

You can start, stop or restart one server: `talisman restart game`.
The old shortcuts `cd /root && ./1 ./2 ./3` and `/root/stop-talisman` still work.

## Where everything is

```
/root/talisman/
├── server/          your server files (upload here)
├── sql/             your .sql dumps (upload here)
├── lib/             extra .so libraries
├── logs/            db_server.log, login_server.log, game_server.log, setup.log
├── backup/          daily database backups (kept 14 days)
├── talisman.conf    settings (ports, program names, autostart, ...)
├── mysql.env        MySQL passwords (keep private!)
└── README-FIRST.txt short reminder of these steps
```

---

## Troubleshooting

Always start with:

```bash
talisman doctor
```

| Problem | Fix |
|---|---|
| `ERROR 1045 Access denied for user 'root'` during setup | Fixed in this version (the old script didn't wait long enough for MySQL). If it still happens, an earlier install left a database with another password. No data to keep: `bash talisman_setup.sh --reset-mysql`. |
| `$'\r': command not found` or `pipefail: invalid option` | The file was saved with Windows line endings. The script now fixes itself; for other files run `sed -i 's/\r$//' file` |
| `error while loading shared libraries: libmysqlclient.so.15` (or `.16`, `.18`) | Old library your server needs. Copy it from your server pack into `/root/talisman/lib/`. `talisman doctor` finds and links versioned copies (like `libmysqlclient.so.15.0.0`) automatically. |
| Server stops right after starting | `talisman logs game` or `talisman console game` shows the reason. Usually wrong DB settings in a config file, or a missing library. |
| `Can't connect to local MySQL server through socket` | Rerun the setup. It shares MySQL's socket at `/run/mysqld/mysqld.sock` (and `/tmp/mysql.sock`) so `localhost` works. Or use `127.0.0.1` in the config. |
| Tables not found, e.g. `Table 'db_game.Player' doesn't exist` | New installs use case-insensitive table names. For older installs, re-import with `--reset-mysql`. |
| Players can't connect | 1) `talisman status` shows which ports the servers use. 2) Open them: `talisman firewall open <port>` (or edit `PUBLIC_PORTS` in `talisman.conf` and run `talisman firewall sync`). 3) Check the **firewall in your VPS provider's web panel** (OVH "Network Firewall" etc.). 4) The IP in the server config and client must be the public IP. |
| Program "not found" although uploaded | Its file name differs from `db_server`/`login_server`/`game_server`. Set the full path in `/root/talisman/talisman.conf`, e.g. `GAME_SERVER_BIN=/root/talisman/server/Game/MyGameSrv` |
| MySQL container keeps stopping | Usually not enough RAM. The setup adds 2 GB swap on small servers; see `talisman logs mysql`. |
| `Could not get lock /var/lib/dpkg/lock` | Ubuntu is installing updates in the background. The setup now waits for it automatically. |

## Setup options

```bash
bash talisman_setup.sh --help
```

| Option | Meaning |
|---|---|
| `--yes` | Don't ask questions |
| `--reset-mysql` | **Delete** all database data and start fresh with new passwords (a last backup is saved first if possible) |
| `--no-firewall` | Don't touch the firewall |
| `--no-swap` | Don't create a swap file |
| `--no-import` | Don't auto-import SQL files at the end |

## What the setup does, in detail

1. Checks the OS, CPU, RAM and disk, and explains any problem.
2. Installs tools and **32-bit libraries** (most Talisman servers are 32-bit programs), waiting for Ubuntu's background updates instead of failing.
3. Adds a 2 GB swap file on servers with less than 4 GB RAM.
4. Installs Docker (or uses the one already installed).
5. Creates `/root/talisman`, a settings file and random MySQL passwords.
6. Runs **MySQL 5.7** in Docker with settings old game servers expect: empty `sql_mode`, utf8, case-insensitive table names, big packets, a capped file limit (prevents MySQL 5.7's huge memory use on new Docker). MySQL listens only on `127.0.0.1`, never on the internet.
7. Waits until MySQL **actually accepts the password**, then creates `db_account`, `db_game`, `db_log`, `db_gmtool` and the `talisman` user, and verifies they exist.
8. Installs the `talisman` command.
9. Creates system services: servers restart after a crash, start on boot in the right order after MySQL, daily backups, log rotation.
10. Turns on the firewall: allows SSH (detected port) and the game ports, blocks everything else. It **no longer wipes** your existing firewall rules.
11. Finds uploaded server files and imports SQL dumps.

## Fixes compared to the first version of the script

- **`ERROR 1045 Access denied` on first run.** The script used `mysqladmin ping` to wait for MySQL. That succeeds *before* the root password is set, so it moved on too early. It now waits for a real login.
- **Databases were never created.** `docker exec` was missing `-i`, so the `CREATE DATABASE` commands never reached MySQL, but the step still looked successful. The setup now also verifies the databases exist.
- **`localhost` in server configs didn't work.** It needs a MySQL socket file on the host. The socket is now shared from the container.
- **MySQL 5.7 could run out of memory** on new Docker versions (unlimited open-files limit). The limit is now capped.
- **`ufw --force reset` wiped all firewall rules** every run. Rules are now only added.
- **`*log*.sql` could match `login` files**, and a dump with its own `USE otherdb` line imported into the wrong database. Both are handled now.
- A stale password file or database volume from an earlier install now gets a clear explanation and `--reset-mysql`.
- Crashed servers stayed down. Now they auto-restart, start on boot, and have rotated logs and daily backups.
- Windows line endings and running with `sh` instead of `bash` are handled automatically.

## Ideas for later

- Auto-editing known server config formats (needs sample config files from real server packs).
- A small web panel for account creation / GM tools.
- Off-server backups (upload to S3 / Google Drive).
- Optional MariaDB instead of MySQL 5.7 (MySQL 5.7 is end-of-life, but it's what most Talisman servers were built for).

## License

Apache 2.0, see [LICENSE](LICENSE).
