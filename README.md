#单IPV4
wget https://raw.githubusercontent.com/sreyyeng/monkey/refs/heads/main/singbox-manager.sh -O /root/singbox-manager.sh && chmod +x /root/singbox-manager.sh && /root/singbox-manager.sh install && ln -sf /root/singbox-manager.sh /usr/local/bin/sb

#V4V6
wget wget -qO- https://raw.githubusercontent.com/sreyyeng/monkey/refs/heads/main/singbox-ipv6.sh | bash

#分流
wget https://raw.githubusercontent.com/sreyyeng/monkey/refs/heads/main/singbox-ip46.sh -O /root/singbox-ip46.sh && chmod +x /root/singbox-ip46.sh && /root/singbox-ip46.sh install

warp
wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
