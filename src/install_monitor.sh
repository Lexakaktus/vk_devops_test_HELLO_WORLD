#!/bin/bash

set -e

INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPTS_DIR="scripts"

echo "Устанавливаем monitor_app.sh..."
sudo cp $SCRIPTS_DIR/monitor_app.sh $INSTALL_DIR/
sudo chmod +x $INSTALL_DIR/monitor_app.sh

echo "Устанавливаем systemd сервис..."
sudo cp $SCRIPTS_DIR/monitor_app.service $SYSTEMD_DIR/

echo "Устанавливаем systemd таймер..."
sudo cp $SCRIPTS_DIR/monitor_app.timer $SYSTEMD_DIR/

echo "Перезагружаем systemd..."
sudo systemctl daemon-reload

echo "Включаем таймер..."
sudo systemctl enable --now monitor_app.timer

echo "Готово!"
