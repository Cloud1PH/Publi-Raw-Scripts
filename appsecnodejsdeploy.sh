#!/bin/bash
          sudo apt update
          sudo snap install amazon-ssm-agent --classic
          sudo systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
          sudo systemctl status snap.amazon-ssm-agent.amazon-ssm-agent.service
          curl -sL https://deb.nodesource.com/setup_12.x | sudo -E bash -
          sudo apt -y install nodejs
          cd /home/ubuntu
          git clone https://github.com/OWASP/NodeGoat.git
          cd NodeGoat/
          npm install
          sudo apt -y install mongodb
          sudo systemctl start mongodb
          sudo systemctl status mongodb
          npm run db:seed
          sudo apt -y install python build-essential
          npm install --save trend_app_protect
          cat <<EOF >trend_app_protect.json
          {
          "key":"${AccessKey}",
          "secret":"${SecretKey}"
          }
          EOF
          sed -i "2 a require('trend_app_protect');" server.js
          npm start
