#单IPV4
wget https://raw.githubusercontent.com/sreyyeng/monkey/refs/heads/main/singbox-manager.sh -O /root/singbox-manager.sh && chmod +x /root/singbox-manager.sh && /root/singbox-manager.sh install && ln -sf /root/singbox-manager.sh /usr/local/bin/sb

#单IPV6
wget https://raw.githubusercontent.com/sreyyeng/monkey/refs/heads/main/singbox-ipv6.sh -O /root/sb6.sh && chmod +x /root/sb6.sh && /root/sb6.sh install && ln -sf /root/sb6.sh /usr/local/bin/sb

#分流
wget https://raw.githubusercontent.com/sreyyeng/monkey/refs/heads/main/singbox-ip46.sh -O /root/singbox-ip46.sh && chmod +x /root/singbox-ip46.sh && /root/singbox-ip46.sh install

warp
wget -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh && bash menu.sh
