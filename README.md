# -Provisioning-Script-for-Hardening-and-Automating-a-VPS-server
Script For Hardening and Automating a Production VPS(Week 1 devops training)



# bootstrap.sh — README

This document explains every command in `bootstrap.sh`, in the order it
runs, and why each one is there. The script provisions a fresh Ubuntu
EC2 instance: it installs Nginx, Node.js, Docker, and the AWS CLI,
creates a dedicated non-root app user, sets up log rotation, schedules
a nightly S3 backup via cron, and deploys a placeholder landing page.

---

## Script-wide settings

```bash
#!/bin/bash
```
The shebang. Tells the system to run this file using bash, regardless
of what shell the user invoking it happens to be using.

```bash
set -euo pipefail
```
Three safety flags combined:
- `-e` — stop the script immediately if any command fails, instead of
  continuing on and potentially making things worse based on a bad
  assumption.
- `-u` — treat any reference to an undefined variable as an error,
  catching typos (like `$APP_USR` instead of `$APP_USER`) instead of
  silently substituting an empty string.
- `-o pipefail` — in a piped command (`a | b`), fail the whole pipeline
  if *either* command fails, not just the last one in the chain.

## Configuration block

```bash
APP_USER="appuser"
APP_DIR="/home/${APP_USER}/app"
LOG_DIR="/var/log/${APP_USER}"
S3_BUCKET="s3://week-1-devops-training-bucket"
BACKUP_SOURCE="${APP_DIR}/data"
```
All the values the rest of the script depends on, defined once at the
top. This means changing the app's username, backup bucket, etc. only
requires editing one line here, instead of hunting through the whole
script for every place it's mentioned.

## `log()` — the logging helper

```bash
log() {
    echo "[$(date +'%F %T')] $1"
}
```
A small reusable function used throughout the rest of the script.
`$(date +'%F %T')` inserts the current date and time (`%F` = full date
`YYYY-MM-DD`, `%T` = time `HH:MM:SS`), and `$1` is whatever message the
function is called with. This exists so every log line in the script's
output is timestamped consistently, without repeating the `date`
command everywhere it's needed.

---

## `update_packages()` — refreshes the package index

```bash
sudo -v
```
Prompts for the sudo password up front, and caches it for a few
minutes. This exists purely so the password prompt happens here, at a
predictable point, rather than interrupting mid-way through a later
step.

```bash
sudo apt update
```
Refreshes apt's local index of what packages and versions are
available from its configured repositories. This doesn't install or
upgrade anything by itself — it just makes sure the *next* install
command knows about the latest available versions. Always run before
installing anything new.

---

## `install_packages()` — installs Nginx, Node.js, npm, Docker

```bash
packages=("nginx" "nodejs" "npm" "docker-ce")
```
An array holding the names of the packages to install, looped over
below rather than writing four separate install blocks.

```bash
for pkg in "${packages[@]}"; do
```
Loops over that array one item at a time, putting each package name
into the variable `$pkg` for that iteration.

```bash
if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
    echo "Package $pkg already installed"
```
Before installing, checks whether the package is already present.
`dpkg-query -W -f='${Status}'` asks dpkg (the low-level package
manager under apt) for the install-status field of that package;
`grep -q "ok installed"` silently checks whether that status says
it's genuinely installed. `2>/dev/null` hides the error dpkg would
otherwise print for a package it's never heard of. This exists so
the script is **safe to re-run** — packages already installed are
skipped instead of apt complaining or wasting time reinstalling them.

```bash
else
    sudo -v
    echo "Installing $pkg package"
    if [ "$pkg" == 'docker-ce' ]; then
        install_docker
    else
        sudo apt install "$pkg" -y
    fi
    echo "Done installing $pkg package"
fi
```
If the package isn't installed: re-cache sudo (in case the earlier
cache expired during a long-running loop), then branch based on which
package this is. `docker-ce` needs a multi-step install (its own repo,
GPG key, etc. — see below), so that case calls the separate
`install_docker` function. Every other package in the list is a normal
one-liner: `sudo apt install "$pkg" -y`, where `-y` auto-confirms the
install so the script doesn't sit waiting for a keypress.

---

## `install_docker()` — the Docker-specific install steps

Docker isn't in Ubuntu's default repositories at the version you want,
so this function adds Docker's own official repository first.

```bash
sudo apt install -y ca-certificates curl gnupg
```
Installs the tools needed to complete the next few steps: certificate
validation, downloading files, and handling GPG signing keys.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
```
Creates the `/etc/apt/keyrings` folder (`-d` = create as a directory)
with permission mode `0755` (owner can read/write/execute, everyone
else can read/execute) — the standard location for storing trusted
repository signing keys.

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```
Downloads Docker's official GPG signing key and converts it
(`--dearmor`) into the binary format apt expects, saving it to the
keyrings folder. This key is what lets apt verify that packages
claiming to be "from Docker" genuinely are, rather than a
malicious impostor package.

```bash
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```
Makes the key file readable by all users (`a+r`) — apt needs to be
able to read it regardless of which user context it's running under.

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```
Writes a new apt repository source file pointing at Docker's official
Ubuntu repo. Two command substitutions build this dynamically instead
of hardcoding values:
- `$(dpkg --print-architecture)` — detects the CPU architecture
  (`amd64`, `arm64`, etc.) so the same script works on different
  instance types.
- `$(. /etc/os-release && echo "$VERSION_CODENAME")` — reads the
  Ubuntu version's codename (e.g. `noble`) so the repo entry matches
  whatever Ubuntu release is actually running.

`sudo tee ... > /dev/null` is used instead of `sudo echo ... > file`
because `sudo` only applies to the command before the `>` — the
redirect itself would run as your normal user and fail to write to a
root-owned path. `tee` writes to the file itself under sudo, and
`> /dev/null` throws away the copy `tee` would otherwise also print to
the screen.

```bash
sudo apt update
```
Refreshes the package index again — now that Docker's repo has been
added, apt needs to re-scan to actually see Docker's packages.

```bash
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```
Installs the actual Docker Engine, its CLI, the container runtime
(`containerd.io`) underneath it, and the modern `docker compose` plugin.

```bash
sudo usermod -aG docker "$USER"
```
Adds the currently logged-in user (`$USER`, a variable bash sets
automatically) to the `docker` group, so they can run `docker`
commands without needing `sudo` every time. `-aG` **appends** to
existing group memberships — using plain `-G` instead would wipe out
any other groups that user already belonged to, so `-a` is essential
here.

---

## `create_app_user()` — creates the dedicated app user

```bash
if id "$APP_USER" &>/dev/null; then
    echo "$APP_USER already exists"
else
    sudo useradd -m -s /bin/bash "$APP_USER"
fi
```
Checks if `appuser` already exists (`id` succeeds silently if so,
`&>/dev/null` hides its output either way) before trying to create it
— this makes the function safe to re-run without erroring on a user
that's already there. `useradd -m -s /bin/bash` creates the user with
a home directory (`-m`) and bash as their login shell (`-s`).

```bash
sudo usermod -aG docker "$APP_USER"
```
Same idea as the earlier `usermod` call, but for `appuser` specifically
— lets the app user run Docker without sudo.

```bash
sudo mkdir -p "$APP_DIR"
```
Creates the app's working directory. `-p` means don't error if it
already exists, and create any missing parent folders along the way.

```bash
sudo chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
```
Hands ownership of that directory — and everything inside it (`-R`,
recursive) — to `appuser`. Without this, the folder would be owned by
`root` (since it was created via `sudo`), and `appuser` wouldn't
actually be able to write to it.

---

## `setup_log_rotation()` — configures logrotate for the app's logs

```bash
sudo mkdir -p "${LOG_DIR}"
sudo chown -R "${APP_USER}:${APP_USER}" "${LOG_DIR}"
```
Same create-and-own pattern as the app directory above — creates
`/var/log/appuser` and hands it to `appuser` so the app (and the
backup script) can actually write log files there.

```bash
sudo tee "/etc/logrotate.d/${APP_USER}" > /dev/null <<EOF
${LOG_DIR}/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 ${APP_USER} ${APP_USER}
}
EOF
```
Writes a logrotate config file using a **heredoc** (`<<EOF ... EOF`) —
a block of text bash treats as a single unit, useful for writing
multi-line files inline in a script rather than via a separate editor
step. Because this heredoc is unquoted (`<<EOF`, not `<<'EOF'`), bash
expands `${LOG_DIR}` and `${APP_USER}` into their actual values before
writing the file.

The logrotate settings themselves:
- `daily` — check for rotation once a day
- `rotate 7` — keep 7 old rotated copies before deleting the oldest
- `compress` — gzip old logs to save space
- `missingok` — don't error if the log file doesn't exist yet
- `notifempty` — don't rotate a log file that's empty (this line was
  originally misspelled as `notifyempty`, which logrotate silently
  ignored rather than erroring on — fixed to the correct directive)
- `create 0640 appuser appuser` — after rotating, create a fresh empty
  log file with permission mode `0640` (owner read/write, group read
  only, others nothing), owned by `appuser`

---

## `setup_s3_backup_cron()` — nightly backup to S3

```bash
sudo mkdir -p "${BACKUP_SOURCE}"
sudo chown "${APP_USER}:${APP_USER}" "${BACKUP_SOURCE}"
```
Creates the folder that actually gets backed up
(`/home/appuser/app/data`) and hands it to `appuser`.

```bash
sudo tee /usr/local/bin/backup-to-s3.sh > /dev/null <<EOF
#!/bin/bash
set -euo pipefail
aws s3 sync "${BACKUP_SOURCE}" "${S3_BUCKET}" --delete
EOF
sudo chmod +x /usr/local/bin/backup-to-s3.sh
```
Writes a second, smaller script — the actual command cron will run
every night — into `/usr/local/bin/`, the standard location for
system-wide custom commands. `aws s3 sync SOURCE DEST` copies any
new or changed files up to S3; `--delete` also removes files from S3
that no longer exist locally, keeping the two genuinely in sync rather
than accumulating stale files forever. `chmod +x` makes the script
executable.

```bash
( sudo crontab -u "${APP_USER}" -l 2>/dev/null || true; \
echo "0 2 * * * /usr/local/bin/backup-to-s3.sh >> ${LOG_DIR}/backup.log 2>&1" \
) | sudo crontab -u "${APP_USER}" -
```
Adds the nightly cron job without wiping out any cron jobs `appuser`
might already have:
- `crontab -u appuser -l` lists appuser's existing crontab.
- `2>/dev/null || true` hides the error (and prevents `set -e` from
  killing the script) that occurs if appuser has no crontab yet.
- The parentheses group that existing list together with the new line
  being added.
- Piping the combined result into `crontab -u appuser -` replaces
  appuser's crontab with "everything that was already there, plus this
  new line" — the standard safe way to add a cron job from a script.
- `0 2 * * *` — cron syntax for "run at 2:00 AM, every day."
- `>> ${LOG_DIR}/backup.log 2>&1` — appends the script's output to a
  log file, and redirects any errors there too, so a failure at 2am
  doesn't just vanish silently.

---

## `deploy_landing_page()` — publishes the placeholder page

```bash
sudo tee /var/www/html/index.html > /dev/null << 'EOF'
<!DOCTYPE html>
...
EOF
```
Writes the landing page HTML using the same heredoc/`tee` pattern as
the logrotate config — but this time the heredoc is **quoted**
(`<< 'EOF'`), which tells bash not to try expanding anything inside
it. There's nothing to expand in this particular HTML, but it's the
correct default for writing HTML/CSS/JS content, since those can
contain `$` characters bash might otherwise try to interpret.
`/var/www/html/` is nginx's default folder for files it serves, so
dropping `index.html` there is enough for nginx to serve it
immediately with no further config changes.

```bash
sudo systemctl restart nginx
sudo systemctl enable nginx
```
`restart` picks up the new page immediately (nginx caches nothing
that would require this, but it's good practice after any change to
served files). `enable` makes nginx start automatically if the
instance ever reboots — without this, a reboot would leave the site
down until someone manually started it again.

---

## `install_awscli()` — installs the AWS CLI

```bash
sudo apt install -y unzip
```
The AWS CLI installer is distributed as a zip file — this ensures the
tool needed to extract it is present.

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
```
Downloads the official installer. `-f` fails silently on server
errors instead of saving an error page as if it were the real file;
`-s` suppresses the progress meter; `-S` re-enables error messages
even with `-s` on; `-L` follows redirects. `-o` specifies where to
save the downloaded file.

```bash
unzip -q /tmp/awscliv2.zip -d /tmp
```
Extracts the zip's contents into `/tmp`. `-q` runs quietly (no file
listing spam), `-d` specifies the destination folder.

```bash
sudo /tmp/aws/install
```
Runs the AWS CLI's own installer script, which places the `aws`
command at `/usr/local/bin/aws` and sets it up to be found on the
system `PATH` automatically.

```bash
rm -rf /tmp/awscliv2.zip /tmp/aws
```
Cleans up the downloaded zip and extracted installer files — they're
no longer needed once the install has completed, so this avoids
leaving clutter in `/tmp`.

---

## `main()` — runs everything in order

```bash
main() {
    log "Provisioning Started"
    update_packages
    install_packages
    install_awscli
    create_app_user
    setup_log_rotation
    setup_s3_backup_cron
    deploy_landing_page
    log "Provisioning complete"
}

main
```
Defines a single function that calls every step above in the correct
order, then calls that function at the very bottom of the script to
actually kick everything off. Structuring the script this way — all
functions defined first, one `main` call at the end — makes it easy to
comment out individual steps while testing (e.g. skipping
`update_packages` on a quick re-run) without having to hunt through
the whole file to find where each step happens.
