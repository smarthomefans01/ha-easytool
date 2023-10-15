#!/bin/bash

# 修改hostname
echo "请选择新的hostname："
echo "1. smarthomefansbox"
echo "2. smarthomefansbox-m"
echo "3. smarthomefansbox-super"
echo "4. smarthomefansbox-max"
echo "5. smarthomefansbox-supreme"
echo "6. smarthomefansbox-easy"
read -p "请输入对应数字：" hostname_number
case $hostname_number in
  1) new_hostname="smarthomefansbox" ;;
  2) new_hostname="smarthomefansbox-m" ;;
  3) new_hostname="smarthomefansbox-super" ;;
  4) new_hostname="smarthomefansbox-max" ;;
  5) new_hostname="smarthomefansbox-supreme" ;;
  6) new_hostname="smarthomefansbox-easy" ;;
  *) echo "输入有误！" exit 1 ;;
esac
echo "当前hostname为$(hostname)，新的hostname为$new_hostname。"
hostnamectl set-hostname $new_hostname

# 安装ntp服务器并同步上海时区的信息，实现开机联网就同步ntp服务器。
echo "正在安装ntp服务器并同步上海时区的信息..."
if ! command -v ntpd &> /dev/null; then 
    apt-get update 
    apt-get install -y ntp 
    apt install -y sntp
fi

# 配置ntp服务器，使用上海时区的NTP服务器，并设置开机自启动ntp服务。
sed -i 's/ubuntu.cn.pool.ntp.org/asia.pool.ntp.org/g' /etc/ntp.conf
sed -i 's/debian.pool.ntp.org/asia.pool.ntp.org/g' /etc/ntp.conf
sed -i 's/de.pool.ntp.org/asia.pool.ntp.org/g' /etc/ntp.conf
sed -i 's/^pool/#pool/g' /etc/ntp.conf
echo "server ntp.aliyun.com" >> /etc/ntp.conf

timedatectl set-timezone Asia/Shanghai 
systemctl enable ntp 

# 检查实际时间和NTP服务器的时间是否同步成功，如果时间差在5分钟以内，则认为时间同步成功。
current_time=$(time -p true 2>&1 | awk '/real/{print $2}')
ntp_time=$(sntp -t 1 ntp.aliyun.com | awk '/^ntp.aliyun.com/{print $3}')

awk -v ct=$current_time -v nt=$ntp_time 'BEGIN{if (sqrt((ct-nt)^2) < 300) print "时间同步成功"; else print "时间同步失败"}'

# 更新系统软件包
echo "正在更新软件包..."
apt update
apt upgrade -y
apt autoremove -y

# 安装依赖项
echo "正在安装依赖项..."
apt --fix-broken install -y
apt-get install jq curl libxcb1 avahi-daemon apparmor-utils udisks2 libglib2.0-bin network-manager dbus wget unzip libmicrohttpd12 systemd-journal-remote -y

# 安装Python和pip
apt update && sudo apt upgrade -y
apt install python3-pip python3-setuptools -y

# 安装msmart
pip3 install msmart

# 安装curl
curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
apt-get install -y curl

# 安装Node.js和npm
apt-get install -y build-essential libavahi-compat-libdnssd-dev libudev-dev libpam0g-dev nodejs

# 安装@tuyapi/cli
npm i @tuyapi/cli -g

# 安装Docker
echo "正在安装Docker..."
curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
systemctl enable docker.service

# 配置Docker镜像加速器
echo "正在配置Docker镜像加速器..."
mkdir -p /etc/docker
tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://hub-mirror.c.163.com"]
}
EOF

# 重启Docker服务并设置开机自启动
echo "正在重启Docker服务..."
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

# 安装容器
echo "正在安装容器..."
docker run --restart=always -it -d -p 3000:3000 --log-opt max-file=1 --log-opt max-size=100m -v /var/run/docker.sock:/var/run/docker.sock smarthomefans/easydockerweb:arm64v8-latest
docker run -it -d -p 5032:5032 --net=host --log-driver json-file --log-opt max-file=1 --log-opt max-size=100m --restart always --name webssh -e TZ=Asia/Shanghai -e savePass=true jrohy/webssh

# 检查容器启动状态
echo "正在检查容器启动状态..."
if docker ps | grep -q "smarthomefans/easydockerweb:arm64v8-latest" && docker ps | grep -q "jrohy/webssh"; then
    echo "容器安装成功，并已启动。"
else
    echo "容器安装失败或未启动。"
fi

echo "脚本执行完毕！"

