# Talisman Online Server Setup (Ubuntu)

This project sets up a **Talisman Online private server** on a Linux VPS
(for example from OVH) for you. You run **one script**, upload your server
files, and type `talisman start`.

**You do not need to know Linux.** Follow the steps in order and copy/paste
the commands. Every step says what you should see.

---

## Contents

1. [What this project does (short version)](#1-what-this-project-does-short-version)
2. [What you need before you start](#2-what-you-need-before-you-start)
3. [Step by step: from a new OVH VPS to a running server](#3-step-by-step-from-a-new-ovh-vps-to-a-running-server)
4. [Everyday commands](#4-everyday-commands)
5. [Where everything is](#5-where-everything-is)
6. [Troubleshooting](#6-troubleshooting)
7. [Updating, reinstalling, uninstalling](#7-updating-reinstalling-uninstalling)
8. [Technical details (for the curious)](#8-technical-details-for-the-curious)

---

## 1. What this project does (short version)

This repository (the files you see on GitHub) contains **one important file**:
`talisman_setup.sh`. It's a script, a list of commands that the server runs for you.

When you run it once on your VPS, it:

| # | What it does | Why |
|---|---|---|
| 1 | Checks your server (Ubuntu version, 64-bit CPU, RAM, disk) | Stops early with a clear message if something is wrong |
| 2 | Installs tools and **32-bit libraries** | Most Talisman server programs are old 32-bit programs |
| 3 | Adds a 2 GB swap file on small servers | So nothing crashes from lack of memory |
| 4 | Installs **Docker** and runs **MySQL 5.7** inside it | The game database. MySQL 5.7 is the version Talisman servers were made for. Only MySQL runs in Docker; your game servers run normally on Ubuntu |
| 5 | Creates the folder `/root/talisman` and random, strong MySQL passwords | One place for everything |
| 6 | Creates the databases `db_account`, `db_game`, `db_log`, `db_gmtool` | Ready for your SQL files |
| 7 | Installs the **`talisman` command** | You use it for everything afterwards (start, stop, import, backup, ...) |
| 8 | Creates services | Servers **restart by themselves if they crash** and **start after a reboot** |
| 9 | Daily database backup + log cleanup | You don't lose data and the disk doesn't fill up |
| 10 | Turns on the firewall | Only SSH and the game ports are open to the internet |

You can run the script **again at any time**. It repairs what's missing and
**never deletes your data** unless you ask it to.

**Supported:** Ubuntu **20.04, 22.04, 24.04** (64-bit). Ubuntu 22.04 or 24.04 is recommended.

---

## 2. What you need before you start

| What | Details |
|---|---|
| **A VPS** | OVH (or any provider). **Ubuntu 22.04 or 24.04**, at least **2 GB RAM** and **20 GB disk** |
| **The VPS IP address** | In the OVH email or the OVH Control Panel, e.g. `51.xx.xx.xx` |
| **The root password** | The one you set (see step 3.2) |
| **Bitvise SSH Client** (free) | One program for both **typing commands** (terminal) and **uploading files** (SFTP). Download: <https://www.bitvise.com/ssh-client-download> |
| **Your 3 server folders** | `db_server`, `login_server`, `game_server`, each with its program, config files and any `lib` folder |
| **Your 3 database files** | `db_account.sql`, `db_game.sql`, `db_log.sql` (plus `db_gmtool.sql` if you have it) |

Your files on your PC should look something like this:

```
My Talisman Server\
├── db_server\            <- folder
│   ├── db_server         <- the program (no .exe, it's a Linux program)
│   └── config files...   (.ini / .cfg / .xml ...)
├── login_server\
│   ├── login_server
│   └── config files...
├── game_server\
│   ├── game_server
│   ├── config files...
│   └── data folders...   (maps, scripts, etc.)
└── database\
    ├── db_account.sql
    ├── db_game.sql
    └── db_log.sql
```

> The program names don't have to match exactly. `DBServer`, `LoginServer`,
> `GameServer`, `dbserver`, ... are found too (see [Troubleshooting](#6-troubleshooting) if yours isn't).

---

## 3. Step by step: from a new OVH VPS to a running server

### 3.1 Prepare the VPS in the OVH Control Panel

1. Log in to the **OVHcloud Control Panel** and open your VPS.
2. If the VPS isn't on Ubuntu yet: click **Reinstall my VPS** and choose
   **Ubuntu 22.04** or **Ubuntu 24.04**. (Reinstalling erases the VPS.)
3. OVH emails you a login. On Ubuntu this is usually the user **`ubuntu`**,
   not `root`.

### 3.2 Connect with Bitvise and activate root

**Install Bitvise SSH Client** on your PC (download link in section 2, click Next → Next → Install).

Open **Bitvise SSH Client**. On the **Login** tab fill in:

| Field | Value |
|---|---|
| Host | your VPS IP (`51.xx.xx.xx`) |
| Port | **22** |
| Username | **root** (or **ubuntu** if you haven't activated root yet) |
| Initial method | **password** |
| Password | your password (tick **Store encrypted password** so you don't have to retype it) |

Click **Log in**. The first time, a window about the **host key** appears: click **Accept and Save**.

After logging in, Bitvise shows buttons on the left:
- **New terminal console**: the black window where you **type commands**
- **New SFTP window**: where you **upload files** (left side = your PC, right side = the VPS)

> **Already activated root and logged in as `root`?** **Skip to 3.3.**

**Activating root** (only if you logged in as `ubuntu`): open **New terminal console** and paste these lines one by one (right-click pastes in the Bitvise terminal):

```bash
sudo passwd root
```
Type a **strong** new password twice. **Nothing appears on screen while you type a password.** That's normal.

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null
sudo systemctl restart ssh
```

Click **Log out** in Bitvise, change **Username** to **root**, enter the new root password, and click **Log in** again.

You're in the right place when the terminal line looks like this:

```
root@vps-xxxxxxxx:~#
```

### 3.3 Download and run the setup

In the Bitvise **terminal console** (logged in as root), paste these two lines:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/colordiscord/TalismanOnlineSetup/main/talisman_setup.sh -o talisman_setup.sh
```

<details>
<summary><b>Got an error like "404" or "Could not resolve"? Upload the file by hand instead</b></summary>

1. On GitHub, open `talisman_setup.sh` and click the **download** button (or "Raw" → Save as).
2. In Bitvise, open **New SFTP window**. On the right side (the VPS) go to `/root`.
3. Drag `talisman_setup.sh` from the left side (your PC) to the right side.
4. Continue below.

</details>

Now start it:

```bash
bash talisman_setup.sh
```

- It takes about **3 to 10 minutes**. You'll see steps `[1/12]`, `[2/12]`, ... with **OK** lines.
- When it's finished you see a big **`SETUP COMPLETE`**.
- If it stops with **ERROR**, read the message: it says what to do. After fixing, just run `bash talisman_setup.sh` again.

The setup creates these **empty folders** for your files:

```
/root/talisman/
├── server/
│   ├── db_server/        <- upload your db_server folder's contents here
│   ├── login_server/     <- upload your login_server folder's contents here
│   └── game_server/      <- upload your game_server folder's contents here
├── sql/                  <- upload db_account.sql, db_game.sql, db_log.sql here
└── lib/                  <- extra .so library files (only if you have them)
```

### 3.4 Upload your server files and databases (Bitvise SFTP)

In Bitvise, click **New SFTP window**.

- **Left side** = your PC. Go to your Talisman server folder.
- **Right side** = the VPS. Type `/root/talisman/server` in the path box at the top and press Enter.

Upload by **dragging from left to right** (or select and click **Upload**):

| From your PC | To the VPS (right side) |
|---|---|
| Everything **inside** your `db_server` folder | `/root/talisman/server/db_server/` |
| Everything **inside** your `login_server` folder | `/root/talisman/server/login_server/` |
| Everything **inside** your `game_server` folder | `/root/talisman/server/game_server/` |
| `db_account.sql`, `db_game.sql`, `db_log.sql` (and `db_gmtool.sql`) | `/root/talisman/sql/` |
| Extra `.so` library files (if your pack has a separate `lib` folder) | `/root/talisman/lib/` |

When you're done it should look like this on the VPS:

```
/root/talisman/server/db_server/db_server          <- program
/root/talisman/server/db_server/...config files
/root/talisman/server/login_server/login_server    <- program
/root/talisman/server/login_server/...config files
/root/talisman/server/game_server/game_server      <- program
/root/talisman/server/game_server/...config + data
/root/talisman/sql/db_account.sql
/root/talisman/sql/db_game.sql
/root/talisman/sql/db_log.sql
```

> **Uploaded a whole folder by accident** (e.g. `server/db_server/db_server/db_server`)?
> No problem: the programs are found anywhere inside `/root/talisman`.

**Is your server pack one `.zip`, `.rar` or `.7z` file?** Upload it to `/root`, then in the Bitvise **terminal** type:

```bash
talisman unpack /root/YourServerPack.zip
```

**Check that everything was found.** In the Bitvise **terminal** type:

```bash
talisman scan
```

You should see **OK** for DB server, Login server, Game server and each SQL file, like this:

```
  OK   DB server     /root/talisman/server/db_server/db_server (ELF 32-bit ...)
  OK   Login server  /root/talisman/server/login_server/login_server (ELF 32-bit ...)
  OK   Game server   /root/talisman/server/game_server/game_server (ELF 32-bit ...)
  OK   SQL file      /root/talisman/sql/db_account.sql -> db_account
  OK   SQL file      /root/talisman/sql/db_game.sql -> db_game
  OK   SQL file      /root/talisman/sql/db_log.sql -> db_log
```

### 3.5 Import the databases

```bash
talisman import
```

Each file is put into the right database based on its name:

| File name contains | Goes into |
|---|---|
| `account` | `db_account` |
| `game` | `db_game` |
| `log` | `db_log` |
| `gmtool` | `db_gmtool` |

It's safe to run twice: databases that already have tables are skipped.
If a file has a strange name, tell it where to go:

```bash
talisman import /root/talisman/sql/myfile.sql db_game
```

### 3.6 Connect your server configs to the database

Your server's config files contain the database **host, user and password**. Show the right values:

```bash
talisman passwords
```

Show which config files you need to change:

```bash
talisman find-config
```

Open a file to edit (use the path that `find-config` showed you):

```bash
nano /root/talisman/server/game_server/config.ini
```

> Prefer editing on your PC? In the Bitvise **SFTP window**, right-click the file on the right side → **Edit**, or download it, edit it with Notepad++, and upload it back.

- Move with the arrow keys and change the values.
- **Save:** `Ctrl + O`, then `Enter`. **Exit:** `Ctrl + X`.

Use these values:

| Setting in the config | Value |
|---|---|
| Host / Server / IP of the database | `127.0.0.1` (or `localhost`; both work) |
| Port | `3306` |
| User / Password | from `talisman passwords` |
| Public IP / external IP for players | your VPS IP (shown by `talisman status`) |

> **Shortcut:** if your configs already have a user and password written in them
> (for example `root` / `123456`), make MySQL accept that instead of editing every file:
> ```bash
> talisman db-user root 123456
> ```

### 3.7 Start the server

```bash
talisman start
```

It starts the **DB server → Login server → Game server** in the right order. Then check:

```bash
talisman status
```

Everything should show **running**. 🎉

From now on:
- A server that **crashes is restarted automatically**.
- After a **VPS reboot**, everything **starts by itself**.
- The database is **backed up every day** at 04:30.

### 3.8 Let players in (ports)

The setup opens ports **8885, 8886 and 8888** in the VPS firewall. `talisman status`
shows the ports your servers **really** use. If you see a different one, open it:

```bash
talisman firewall open 9000
```

**OVH has its own firewall too** (OVH Control Panel → *Network* → *IP* → the `...` next
to your IP → **Network Firewall**). It's **off by default**. If you turned it on, allow the same ports there.

Players' game clients must connect to **your VPS IP**.

---

## 4. Everyday commands

Log in with Bitvise as root, open **New terminal console**, and type:

| Command | What it does |
|---|---|
| `talisman start` | Start all servers (db → login → game) |
| `talisman stop` | Stop all servers |
| `talisman restart` | Stop and start again (use after editing configs) |
| `talisman status` | What's running, ports, server IP, last backup |
| `talisman logs game` | Watch the game server log live (`db`, `login`, `mysql`, `all` also work). **`Ctrl + C`** to exit |
| `talisman doctor` | ⭐ **Checks everything and tells you how to fix problems** |
| `talisman console game` | Run one server in the foreground to see its errors directly. `Ctrl + C` to stop |
| `talisman backup` | Back up all databases now |
| `talisman restore` | List backups / restore one |
| `talisman sql db_game` | Open a MySQL prompt (type `exit` to leave) |
| `talisman passwords` | Show database user and password |
| `talisman firewall open 9000` | Open a port for players |
| `talisman autostart on` / `off` | Start servers after reboot (on by default) |
| `talisman help` | All commands |

One server only: `talisman restart game`, `talisman stop login`, `talisman start db`.

The short commands from the old script still work: `cd /root` then `./1`, `./2`, `./3`, and `/root/stop-talisman`.

---

## 5. Where everything is

```
/root/talisman/
├── server/
│   ├── db_server/     your db_server files
│   ├── login_server/  your login_server files
│   └── game_server/   your game_server files
├── sql/               db_account.sql, db_game.sql, db_log.sql
├── lib/               extra .so library files
├── logs/              db_server.log, login_server.log, game_server.log, setup.log
├── backup/            daily database backups (kept 14 days)
├── talisman.conf      settings (ports, program names, autostart, ...)
├── mysql.env          MySQL passwords (keep this private!)
└── README-FIRST.txt   short reminder of the steps
```

Change settings with `nano /root/talisman/talisman.conf`, then `talisman restart`.

---

## 6. Troubleshooting

**Always start with:**

```bash
talisman doctor
```

It checks the system, MySQL, your server programs, missing libraries and ports,
and prints a `->` hint with the fix for each problem.

| You see... | What to do |
|---|---|
| `ERROR 1045 Access denied for user 'root'` during setup | Fixed in this version (the old script didn't wait long enough for MySQL). If it still happens, an earlier install left a database with another password. **No data to keep?** Run `bash talisman_setup.sh --reset-mysql` |
| `$'\r': command not found` or `pipefail: invalid option` | The file was saved on Windows. The setup fixes itself now. For other files: `sed -i 's/\r$//' filename` |
| `error while loading shared libraries: libmysqlclient.so.15` (or `.16`, `.18`) | Your server needs an old library. Copy it from your server pack into `/root/talisman/lib/`. `talisman doctor` finds and links versioned copies (like `libmysqlclient.so.15.0.0`) automatically |
| A server stops right after starting | See why: `talisman logs game` or `talisman console game`. Usually a wrong database setting in a config file, or a missing library |
| `Can't connect to local MySQL server through socket` | Run `bash talisman_setup.sh` again, or use `127.0.0.1` instead of `localhost` in the config |
| `Table 'db_game.Player' doesn't exist` (upper/lower case) | New installs ignore upper/lower case in table names. Older installs: re-import after `--reset-mysql` |
| Players can't connect | 1) `talisman status`: are all 3 running? Which ports? 2) `talisman firewall open <port>` for each game port. 3) Check the **OVH Network Firewall** (step 3.8). 4) The server configs and the game client must use your **VPS public IP** |
| `program not found` although you uploaded it | Its file name is different. Set the full path in `/root/talisman/talisman.conf`, e.g. `GAME_SERVER_BIN=/root/talisman/server/game_server/MyGameSrv`, then `talisman start` |
| MySQL keeps stopping | Usually too little RAM. Check `talisman logs mysql` |
| `Could not get lock /var/lib/dpkg/lock` | Ubuntu is updating in the background. The setup waits automatically; just wait |
| `Permission denied` / `Please run as root` | You're not root. Type `sudo -i` first |
| You closed Bitvise. Did the server stop? | No. The servers keep running without you. Log in again any time |

---

## 7. Updating, reinstalling, uninstalling

| Goal | Command |
|---|---|
| Get the newest version of this setup | `talisman self-update` |
| Repair / re-apply the setup (safe, keeps data) | `bash /root/talisman_setup.sh` |
| Start the database from zero (**deletes all accounts and characters!**) | `bash /root/talisman_setup.sh --reset-mysql` |
| Remove everything except your data | `talisman uninstall` |
| Remove everything **including** data and files | `talisman uninstall --purge` |

Setup options (`bash talisman_setup.sh --help`):

| Option | Meaning |
|---|---|
| `--yes` | Don't ask questions |
| `--reset-mysql` | **Delete** all database data and start fresh with new passwords (a last backup is saved first if possible) |
| `--no-firewall` | Don't touch the firewall |
| `--no-swap` | Don't create a swap file |
| `--no-import` | Don't auto-import SQL files at the end |

---

## 8. Technical details (for the curious)

<details>
<summary><b>How MySQL and Docker are used</b></summary>

- MySQL 5.7 runs in a Docker container called `talisman-mysql`. The data is stored in the Docker volume `talisman_mysql`, so it survives container restarts and upgrades.
- **Only MySQL runs in Docker.** `db_server`, `login_server` and `game_server` run directly on Ubuntu (as systemd services `talisman-db`, `talisman-login`, `talisman-game`).
- MySQL listens only on `127.0.0.1:3306`, so it can't be reached from the internet. Its socket is shared at `/run/mysqld/mysqld.sock` (and `/tmp/mysql.sock`), so configs using `localhost` work too.
- MySQL settings suited to old game servers: empty `sql_mode`, utf8, case-insensitive table names (new installs), `max_allowed_packet=256M`, and a capped open-file limit (MySQL 5.7 otherwise uses huge amounts of RAM on new Docker versions).

</details>

<details>
<summary><b>What changed compared to the first version of the script</b></summary>

- **`ERROR 1045 Access denied` on first run.** The script waited for MySQL with `mysqladmin ping`, which succeeds *before* the root password is set. It now waits for a real login.
- **Databases were never created.** `docker exec` was missing `-i`, so the `CREATE DATABASE` commands never reached MySQL, but the step still looked successful. The setup now also verifies the databases exist.
- **`localhost` in server configs didn't work.** The MySQL socket is now shared with the host.
- **MySQL 5.7 could run out of memory** on new Docker versions. The open-file limit is now capped.
- **`ufw --force reset` wiped all firewall rules** on every run. Rules are now only added.
- **`*log*.sql` could match `login` files**, and dumps with their own `USE otherdb` line went into the wrong database. Both are handled.
- A stale password or old database from an earlier install gets a clear explanation, plus `--reset-mysql`.
- New: crash auto-restart, start on boot, daily backups, log rotation, swap, the `talisman` command with `doctor`, archive unpacking, Windows line-ending fix.

</details>

<details>
<summary><b>Ideas for later</b></summary>

- Auto-editing known server config formats (needs sample config files from real server packs).
- A small web panel for account creation / GM tools.
- Off-server backups (upload to cloud storage).

</details>

---

## License

Apache 2.0, see [LICENSE](LICENSE).
