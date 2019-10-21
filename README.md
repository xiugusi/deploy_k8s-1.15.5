### centos7.7 部署 Kubernetes-1.15.x版本

编辑options.conf文件，可以安装指定版本，目前测试过1.15.1 ~ 1.15.5

安装步骤：
#### 1、修options.conf里面的参数:
```
#1 更换yum源为Aliyun源，0不更换yum源
aliyun="0"
masterip="192.168.124.135"
k8s_version="v1.15.1"
root_passwd="123456"
hostname="k8s"
hostip=(
192.168.124.135
192.168.124.136
192.168.124.137
)```

#### 2、脚本授权，并执行安装
```
chmox +x master_install.sh && ./master_install.sh
```

#### 3、安装过程会输出到屏幕，同时保存在当前目录的install.log文件

#### 4、虚拟机cpu必须最少是2个！切记
