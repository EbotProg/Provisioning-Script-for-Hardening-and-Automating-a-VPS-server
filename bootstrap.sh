#!/bin/bash
set -euo pipefail

#Configuration
APP_USER="appuser"
APP_DIR="/home/${APP_USER}/app"
LOG_DIR="/var/log/${APP_USER}"
S3_BUCKET="s3://week-1-devops-training-bucket"
BACKUP_SOURCE="${APP_DIR}/data"


echo "###############################################################################################################"
echo "# Hello, I'm Achale Ebot. This is my first script which I will be excuting in this journey of learning devops #"
echo "# This is my Week 1 Milestone Project                                                                         #"
echo "###############################################################################################################"

# log
log() {
	echo "[$(date +'%F %T')] $1"
}

#updates packages by running sudo apt update command
update_packages() {
	echo "###############################################################################################################"
        echo "#                                                                                                             #"
	echo "# 1. Update Packages                                                                                          #"
	echo "#                                                                                                             #"
	echo "###############################################################################################################"
	echo "####About to update packages. But will need your permission first......"
	sudo -v
	echo "####Updating package list..."
	sudo apt update
	echo "####Package Update Done"
}


#installs default packages
install_packages() {
        echo "###############################################################################################################"
        echo "#                                                                                                             #"
        echo "# 3. Install Nginx, Nodejs+Npm and docker-ce Packages                                                                                   #"
        echo "#                                                                                                             #"
        echo "###############################################################################################################"
	packages=("nginx" "nodejs" "npm" "docker-ce")
        echo "### Checking if the packages ${packages[@]} are installed before installing....."
	for pkg in "${packages[@]}"; do
		echo "Checking if $pkg is installed"
		if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
			echo "Package $pkg already installed"
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
	done
}

#install docker
install_docker() {
echo "Installing prerequisites..."
sudo apt install -y ca-certificates curl gnupg

echo "Adding Docker's official GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "Adding Docker's repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Updating package list again (now includes Docker's repo)..."
sudo apt update

echo "Installing Docker..."
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "Adding your user to the docker group so you don't need sudo every time..."
sudo usermod -aG docker "$USER"

}

#Creates app user
create_app_user() {
	if id "$APP_USER" &>/dev/null; then
		echo "$APP_USER already exists"
	else
		echo "creating app user: $APP_USER....."
		sudo useradd -m -s /bin/bash "$APP_USER"
	fi
	echo "adding $APP_USER to docker group...."
                sudo usermod -aG docker "$APP_USER"
                echo "creating app directory..."
                sudo mkdir -p "$APP_DIR"
                echo "Changing owner and group for app directory to app user: $APP_USER...."
                sudo chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
                echo "Done creating app user: $APP_USER"
}

# Setup log rotation
setup_log_rotation() {
	log "creating log directory..."
	sudo mkdir -p "${LOG_DIR}"
	sudo chown -R "${APP_USER}:${APP_USER}" "${LOG_DIR}"

	log "Writing lograte config for ${APP_USER}..."
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
}

setup_s3_backup_cron() {
	log "Creating backup script..."
	sudo mkdir -p "${BACKUP_SOURCE}"
	sudo chown "${APP_USER}:${APP_USER}" "${BACKUP_SOURCE}"

	sudo tee /usr/local/bin/backup-to-s3.sh > /dev/null <<EOF
#!/bin/bash
set -euo pipefail
aws s3 sync "${BACKUP_SOURCE}" "${S3_BUCKET}" --delete
EOF
	sudo chmod +x /usr/local/bin/backup-to-s3.sh

	log "Adding nightly cron job (2am) to ${APP_USER}'s crontab..."
	( sudo crontab -u "${APP_USER}" -l 2>/dev/null || true; \
	echo "0 2 * * * /usr/local/bin/backup-to-s3.sh >> ${LOG_DIR}/backup.log 2>&1" \
	) | sudo crontab -u "${APP_USER}" -
}

deploy_landing_page() {
	log "Writing landing page to /var/www/html/index.html..."
	sudo tee /var/www/html/index.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html>
<head><title>Coming Soon</title></head>
<body style="text-align:center; margin-top:100px; font-family:sans-serif;">
  <h1>Coming Soon</h1>
  <p>We're working on something great.</p>
</body>
</html>
EOF

	log "Restarting and enabling nginx..."
	sudo systemctl restart nginx
	sudo systemctl enable nginx
}

install_awscli() {
    log "Installing AWS CLI..."
    sudo apt install -y unzip
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    sudo /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws
}

main() {
log "Provisioning Started"
#1. update packages
update_packages

#2. Install Nginx, Nodejs and Npm Packages
install_packages

install_awscli
create_app_user

setup_log_rotation

setup_s3_backup_cron

deploy_landing_page

log "Provisioning complete"
}

main
