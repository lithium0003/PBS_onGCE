#!/bin/bash

zone=asia-northeast1-b
user=username
homedisk=home
homesize='100GB'
sshkey='ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKeT5lV60kIk2A3uwdPupRTlwFYqjteYwEubNc9+UtQRbUoqd41iyu5Pis8D5WI0Zxc/QNjlC8KgXiUyOp3Ect0= yubikey'

num_compute=14

if gcloud compute disks list | grep $homedisk; then
	disk_exists='ok'
else
	disk_exists=''
	gcloud compute disks create $homedisk --type pd-ssd --size $homesize --zone $zone
fi

gcloud compute instances create master --boot-disk-type pd-ssd --image-family debian-9 --image-project debian-cloud --disk name=$homedisk --machine-type n1-highcpu-8 --scopes default,compute-rw --zone $zone

gcloud compute ssh master --zone $zone --command 'sudo apt update && sudo apt upgrade -y'
gcloud compute ssh master --zone $zone --command 'sudo apt -y install nfs-kernel-server whois less libpam-systemd dbus'
cat /dev/zero | gcloud compute ssh master --zone $zone --command 'sudo reboot'
sleep 30

if [ -z $disk_exists ]; then
	gcloud compute ssh master --zone $zone --command 'sudo mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/sdb'
fi
gcloud compute ssh master --zone $zone --command 'echo UUID=`sudo blkid -s UUID -o value /dev/sdb` /home ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab'
gcloud compute ssh master --zone $zone --command 'sudo reboot'
sleep 30

if [ -z $disk_exists ]; then
	gcloud compute ssh master --zone $zone --command "sudo useradd -m -s /bin/bash -p \$(echo test | mkpasswd -s -m sha-512) $user"
	gcloud compute ssh master --zone $zone --command "cat /dev/zero | sudo -u $user ssh-keygen -t ed25519 -q -N ''"
	gcloud compute ssh master --zone $zone --command "sudo -u $user cat /home/$user/.ssh/id_ed25519.pub | sudo -u $user tee -a /home/$user/.ssh/authorized_keys"
	gcloud compute ssh master --zone $zone --command "echo '$sshkey' | sudo -u $user tee -a /home/$user/.ssh/authorized_keys"
else
	gcloud compute ssh master --zone $zone --command "sudo useradd $user -s /bin/bash"
fi
gcloud compute ssh master --zone $zone --command "sudo gpasswd -a $user google-sudoers"
gcloud compute ssh master --zone $zone --command "echo '/home   10.0.0.0/8(rw,async,wdelay,no_subtree_check)' | sudo tee -a /etc/exports"
gcloud compute ssh master --zone $zone --command 'sudo reboot'
sleep 30
gcloud compute ssh master --zone $zone --command 'sudo apt install -y gcc gfortran make libtool libhwloc-dev libx11-dev libxt-dev libedit-dev libical-dev ncurses-dev perl postgresql-server-dev-all postgresql-contrib python-dev tcl-dev tk-dev swig libexpat-dev libssl-dev libxext-dev libxft-dev autoconf automake'

if [ -z $disk_exists ]; then
	gcloud compute ssh master --zone $zone --command 'wget https://github.com/PBSPro/pbspro/releases/download/v19.1.1/pbspro-19.1.1.tar.gz'
	gcloud compute ssh master --zone $zone --command 'tar -xpvf pbspro-19.1.1.tar.gz'
	gcloud compute ssh master --zone $zone --command 'cd pbspro-19.1.1 && ./autogen.sh && ./configure --prefix=/opt/pbs && make -j 4 && sudo make install && sudo /opt/pbs/libexec/pbs_postinstall && sudo chmod 4755 /opt/pbs/sbin/pbs_iff /opt/pbs/sbin/pbs_rcp'
else
	gcloud compute ssh master --zone $zone --command 'cd pbspro-19.1.1 && sudo make install && sudo /opt/pbs/libexec/pbs_postinstall && sudo chmod 4755 /opt/pbs/sbin/pbs_iff /opt/pbs/sbin/pbs_rcp'
fi
### if use master node for compute, uncomment this line ###
#gcloud compute ssh master --zone $zone --command "sudo sed -i 's/PBS_START_MOM=0/PBS_START_MOM=1/' /etc/pbs.conf"
echo '$usecp *:/home/ /home/' | gcloud compute ssh master --zone $zone --command 'sudo tee -a /var/spool/pbs/mom_priv/config'
gcloud compute ssh master --zone $zone --command 'sudo reboot'
sleep 30

gcloud compute ssh master --zone $zone --command 'sudo apt install -y squid3'
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(http_access allow localnet\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(http_access deny to_localhost\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(acl localnet src 10.0.0.0/8.*\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(acl localnet src 172.16.0.0/12.*\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(acl localnet src 192.168.0.0/16.*\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(acl localnet src fc00\:\:/7.*\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo sed -i 's:#\(acl localnet src fe80\:\:/10.*\):\1:' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command 'cat <<EOF | sudo tee -a /etc/squid/squid.conf
acl to_metadata dst 169.254.169.254
http_access deny to_metadata
EOF
'
gcloud compute ssh master --zone $zone --command "sudo sed -i 's/http_port 3128/http_port 0.0.0.0:3128/' /etc/squid/squid.conf"
gcloud compute ssh master --zone $zone --command "sudo service squid restart"


cat << EOM | gcloud compute ssh master --zone $zone --command 'cat >shutdown.sh' 
#!/bin/bash

if [[ `curl "http://metadata.google.internal/computeMetadata/v1/instance/preempted" -H "Metadata-Flavor: Google"` == 'TRUE' ]]
then
	date >> /var/lib/misc/preempted
fi
EOM

cat << 'EOM' | gcloud compute ssh master --zone $zone --command 'cat >compute.sh && chmod +x compute.sh' 
#!/bin/bash

host=compute$1
zone=asia-northeast1-b
user=asuka

gcloud compute instances create $host --boot-disk-type pd-ssd --image-family debian-9 --image-project debian-cloud --machine-type n1-highcpu-16 --zone $zone --preemptible --no-address --metadata-from-file shutdown-script=shutdown.sh || exit 1

cat /dev/zero | gcloud compute ssh $host --zone $zone --internal-ip --command 'exit'
txt=$(cat << 'EOF'
echo 'http_proxy="http://master.$(dnsdomainname):3128"' >> /etc/environment
echo 'https_proxy="http://master.$(dnsdomainname):3128"' >> /etc/environment
echo 'ftp_proxy="http://master.$(dnsdomainname):3128"' >> /etc/environment
echo 'no_proxy=169.254.169.254,metadata,metadata.google.internal' >> /etc/environment
cp /etc/sudoers /tmp/sudoers.new
chmod 640 /tmp/sudoers.new
echo "Defaults env_keep += \"ftp_proxy http_proxy https_proxy no_proxy"\" >>/tmp/sudoers.new
chmod 440 /tmp/sudoers.new
visudo -c -f /tmp/sudoers.new && cp /tmp/sudoers.new /etc/sudoers
EOF
)
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && echo '$txt' >/tmp/setproxy.sh && chmod +x /tmp/setproxy.sh" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command '[[ ! -f /var/lib/misc/preempted ]] && sudo /tmp/setproxy.sh' || exit 1

gcloud compute ssh $host --zone $zone --internal-ip --command '[[ ! -f /var/lib/misc/preempted ]] && sudo apt update && sudo apt upgrade -y' || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command '[[ ! -f /var/lib/misc/preempted ]] && sudo apt install -y nfs-common libpam-systemd dbus' || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && echo 'master:/home /home nfs rw,hard,intr,exec,lookupcache=none 0 0' | sudo tee -a /etc/fstab" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command 'sudo reboot' &
sleep 1
kill $!
sleep 30

gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo useradd $user -s /bin/bash" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo gpasswd -a $user google-sudoers" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command 'sudo reboot'
sleep 30

gcloud compute ssh $host --zone $zone --internal-ip --command '[[ ! -f /var/lib/misc/preempted ]] && sudo apt install -y gcc gfortran make libtool libhwloc-dev libx11-dev libxt-dev libedit-dev libical-dev ncurses-dev perl postgresql-server-dev-all postgresql-contrib python-dev tcl-dev tk-dev swig libexpat-dev libssl-dev libxext-dev libxft-dev autoconf automake' || exit 1

gcloud compute ssh $host --zone $zone --internal-ip --command '[[ ! -f /var/lib/misc/preempted ]] && cd pbspro-19.1.1 && sudo make install && sudo /opt/pbs/libexec/pbs_postinstall && sudo chmod 4755 /opt/pbs/sbin/pbs_iff /opt/pbs/sbin/pbs_rcp' || exit 1

gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo sed -i 's/PBS_SERVER=.*/PBS_SERVER=master/' /etc/pbs.conf" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo sed -i 's/PBS_START_SERVER=1/PBS_START_SERVER=0/' /etc/pbs.conf" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo sed -i 's/PBS_START_SCHED=1/PBS_START_SCHED=0/' /etc/pbs.conf" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo sed -i 's/PBS_START_MOM=0/PBS_START_MOM=1/' /etc/pbs.conf" || exit 1
sed_cmd='s/$clienthost.*/$clienthost master/'
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]] && sudo sed -i '$sed_cmd' /var/spool/pbs/mom_priv/config" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command "echo '\$usecp *:/home/ /home/' | sudo tee -a /var/spool/pbs/mom_priv/config"
gcloud compute ssh $host --zone $zone --internal-ip --command "[[ ! -f /var/lib/misc/preempted ]]" || exit 1
gcloud compute ssh $host --zone $zone --internal-ip --command 'sudo reboot'

exit 0
EOM

cat << 'EOM' | gcloud compute ssh master --zone $zone --command 'cat >run.sh && chmod +x run.sh' 
#!/bin/bash

zone=asia-northeast1-b

if [[ -f "/home/$(whoami)/stop_running" ]]
then
	exit
fi

for node in `gcloud compute instances list | grep 'compute' | grep -v 'RUNNING' | awk '{print $1}'`
do
	echo $node
	gcloud compute instances start $node --zone $zone
done
EOM


cat << EOM | gcloud compute ssh master --zone $zone --command 'cat >create.sh && chmod +x create.sh' 
#!/bin/bash

if [[ \$1 ]]
then
	waitlist=\$1
else
    rm -f create*.log
    seq $num_compute > "create.wait"
	waitlist="create.wait"
fi

rm -f create.failed
while read c
do
	{
		sleep \$((c * 3))
		./compute.sh \$c > create\$c.log 2>&1
		if [[ \$? ]]
		then
			sudo /opt/pbs/bin/qmgr -c "create node compute\$c"
		else
			echo \$c >> create.failed
		fi
	}&
done < <(cat "\$waitlist")

wait

if [[ -f create.failed ]]
then
	cat create.failed | while read f
	do
		gcloud compute instances delete compute\$f --zone $zone
	done

	if [[ \$2 > 5 ]]
	then
		exit 1
	else
		mv create.failed create.wait
		count=\$2
		./create.sh create.wait \$((count + 1))
	fi
else
	exit 0
fi
EOM

gcloud compute ssh master --zone $zone --command 'echo "*/5 * * * * /home/$(whoami)/run.sh" | crontab -'
gcloud compute ssh master --zone $zone --command './create.sh'
