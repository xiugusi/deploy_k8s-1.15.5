#!/bin/bash
## 建议所有服务器手动执行yum upgrade到最新内核，重启服务后再执行此脚本安装

home_path=$(pwd)
source $home_path/options.conf

# Check if user is root
[[ "$(whoami)" != "root" ]] && { echo "Error: You must be root to run this script" ; exit 1 ; }

# get local IP address
ipaddr=$(ip -4 a | awk -F '[/ ]+' '/'${masterip%.*}'/{print $3}')


yum_package(){
yum install -y wget

# update yum source to Aliyun 
if [ $aliyun == "1" ];then
    cd /etc/yum.repos.d/ && \
    if test -d repo_bak;then
       [[ ! -s CentOS-Base.repo ]] && wget -O CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo && wget -O epel.repo http://mirrors.aliyun.com/repo/epel-7.repo
    else
      mkdir repo_bak && mv -f *.repo repo_bak/
      wget -O CentOS-Base.repo http://mirrors.aliyun.com/repo/Centos-7.repo && wget -O epel.repo http://mirrors.aliyun.com/repo/epel-7.repo
      yum clean all && yum makecache
    fi
fi

# install packages
num=0
while [ 1 ]
do
    let num+=1
    yum -y install iotop yum-utils net-tools git lrzsz expect gcc gcc-c++ make libxml2-devel openssl-devel curl curl-devel unzip libaio-devel vim ncurses-devel autoconf automake zlib-devel python-devel bash-completion
    if [ $? -eq 0 ]; then
        echo "yum安装软件包成功！！"
        break
    elif [ $num -gt 1 ]; then
        echo "yum安装失败，请手动执行依赖安装？？"
        break && exit
    fi
done
}


system_setup(){
#firewalld
if [[ `ps -ef | grep -c firewalld` -gt 1 ]];then
    systemctl stop firewalld && systemctl disable firewalld
    systemctl stop iptables -q &>/dev/null && systemctl disable iptables
fi

# close selinux
setenforce 0
sed -i 's/^SELINUX=.*$/SELINUX=disabled/' /etc/selinux/config

# sync time
if [[ `ps -ef | grep chrony |wc -l` -eq 1 ]];then
    timedatectl set-local-rtc 1 && timedatectl set-timezone Asia/Shanghai
    yum -y install chrony && systemctl restart chronyd && systemctl enable chronyd
fi

# setup ulimit
ulimit -SHn 102400
sed -i '/^# End of file/,$d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
# End of file
*	soft  nofile       102400
*	hard  nofile       102400
*	soft  nproc        102400
*	hard  nproc        102400
*	soft  memlock      unlimited 
*	hard  memlock      unlimited
EOF


# sysctl_config
if [ ! -f /etc/sysctl.d/k8s.conf ];then
cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
kernel.pid_max=4194303
# vip无法绑定时，设置为1
net.ipv4.ip_nonlocal_bind = 1
# 关闭swap
vm.swappiness=0
EOF
sysctl -p /etc/sysctl.d/k8s.conf
fi

# swapoff
/sbin/swapoff -a
sed -i -r '/swap/s/^(#)?/#/' /etc/fstab

# ssh config
if [ `grep -c 'UserKnownHostsFile' /etc/ssh/ssh_config` -eq 0 ];then
    sed -i "2i StrictHostKeyChecking no\nUserKnownHostsFile /dev/null" /etc/ssh/ssh_config
    sed -i '/UseDNS/s@.*@UseDNS no@' /etc/ssh/sshd_config
fi
}


install_docker(){
which docker &>/dev/null
if [ $? -eq 0 ];then
    echo "docker已安装完毕！！"
else
    mkdir -p /etc/docker
    yum-config-manager --add-repo  https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
    yum install -y --setopt=obsoletes=0 docker-ce-18.09.4-3.el7
    cat > /etc/docker/daemon.json << EOF
{
  "registry-mirrors": ["https://l10nt4hq.mirror.aliyuncs.com"]
}
EOF
fi
systemctl daemon-reload && systemctl restart docker && systemctl enable docker && echo "docker已安装完毕！！" || { echo 'docker安装失败？？' ; exit 1 ; }
}


rootssh_trust(){
cd $home_path
for host in ${hostip[@]}
do
  if [ "$host" != "$ipaddr" ];then
    if [[ -s /root/.ssh/id_rsa.pub ]];then
      expect ssh_trust_add.exp $root_passwd $host
    else
      expect ssh_trust_init.exp $root_passwd $host
    fi
    echo "服务器互信完成！！！ "
  fi
done
}

install_k8s(){
if [ ! -f /etc/yum.repos.d/kubernetes.repo ];then
cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
fi

which kubeadm &>/dev/null
if [ $? -ne 0 ];then
    yum install -y kubelet-${k8s_version#v} kubeadm-${k8s_version#v} kubectl-${k8s_version#v} kubernetes-cni-0.7.5 && \
    systemctl daemon-reload && systemctl restart kubelet && systemctl enable kubelet || { echo 'K8s安装失败？？' ; exit 1 ; }
fi
[[ -s /usr/share/bash-completion/bash_completion ]] && source /usr/share/bash-completion/bash_completion && source <(kubectl completion bash)
}


pull_images(){
cd $home_path
images=(
kube-proxy:${k8s_version}
pause:3.1
)
for imagename in ${images[@]}; do
  if [ -f images/${imagename}.tar ];then
    docker load -i images/${imagename}.tar
  else
    docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/$imagename
    docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/$imagename k8s.gcr.io/$imagename
    docker rmi registry.cn-hangzhou.aliyuncs.com/google_containers/$imagename
  fi
done

if [ -f images/coredns:1.3.1.tar ];then
    docker load -i images/coredns:1.3.1.tar
else
    docker pull registry.cn-hangzhou.aliyuncs.com/openthings/k8s-gcr-io-coredns:1.3.1
    docker tag registry.cn-hangzhou.aliyuncs.com/openthings/k8s-gcr-io-coredns:1.3.1 k8s.gcr.io/coredns:1.3.1
    docker rmi registry.cn-hangzhou.aliyuncs.com/openthings/k8s-gcr-io-coredns:1.3.1
fi

[[ -f images/flannel_${flannel_version}.tar ]] && docker load -i images/flannel_${flannel_version}.tar || docker pull quay.io/coreos/flannel:${flannel_version}
}


join_cluster(){
kubeadm join $masterip:6443 --token $token --discovery-token-ca-cert-hash sha256:$sha_value
test -d /root/.kube || mkdir /root/.kube
cp /etc/kubernetes/bootstrap-kubelet.conf /root/.kube/config
}


install_flannel(){
cd $home_path
test -f kube-flannel.yml || wget https://raw.githubusercontent.com/coreos/flannel/62e44c867a2846fefb68bd5f178daf4da3095ccb/Documentation/kube-flannel.yml
kubectl apply -f kube-flannel.yml
[ `docker images |grep -c $flannel_version` -gt 0 ] && echo "flannel 网络配置完毕！！" || echo "flannel 网络配置失败，请手动下载tar包并放在images目录！！"
}


main(){
echo -e '\n配置yum源\n' 
yum_package
echo -e '\n配置系统\n' 
system_setup
echo -e '\n安装docker\n'
install_docker
echo -e '\nssh互信配置\n'
rootssh_trust 
echo -e '\n安装 K8s master\n'
install_k8s
echo -e '\n拉取镜像\n'
pull_images
echo -e '\n加入master\n'
join_cluster
echo -e '\n安装网络组件flannel\n'
install_flannel
}

## run
main
