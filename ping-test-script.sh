#!/bin/bash

# 0. 定义参数值
ip="www.baidu.com" # 待测IP
namespace="example" # CloudWatch中的概念，是Metrics的容器
time=90 # Ping多久，单位是分钟
pingcount=10 # Ping几次
region="ap-northeast-2" # 运行命令Region

# 1. 生成秘钥对
mkdir ~/ping-test
cd ~/ping-test/
sudo ssh-keygen -t RSA -N '' -f ~/ping-test/id_rsa_test
sudo chown ec2-user:ec2-user id_rsa_test*
mv id_rsa_test.pub ping-test-key.pub

# 2. 升级awscli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# 3. 设定并发值
regionlist=$(aws ec2 describe-regions --query "Regions[*].RegionName" --region $region --output text) # 获取账号中已激活的Region列表
Concurrent=$(echo "$regionlist" | wc -w) # 按照已激活的Region数量设定并发值
mkfifo bl.fifo
exec 4<> bl.fifo
rm bl.fifo

# 4. 开始并发任务
for i in $(seq 1 "$Concurrent")
do
    echo >&4 # 写入空值到fifo管道
done

for region in $regionlist;
do
    read <&4 # 从fifo管道中读取空值
    (
        echo "----------$region----------"

        # 1. 导入秘钥
        cd ~/ping-test || exit
        aws ec2 import-key-pair --key-name "ping-test-key" --public-key-material fileb://ping-test-key.pub --region "$region"
        if [ "$?" != 0 ]; then
            echo "--------------------key has already existed--------------------"
        fi

        # 2. 新建实例
        # 2.1 确定实例类型
        instancetype=$(aws ec2 describe-instance-types --region "$region" --filter "Name=instance-type,Values=t2.micro" --query "InstanceTypes[0].InstanceType") # 如果这个Region有t2.micro，则使用t2.micro，否则使用t3.micro
        if [ $instancetype != null  ]; then
            instanceid=$(aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 --instance-type t2.micro --key-name ping-test-key --region "$region" --query 'Instances[0].InstanceId' --output text)
        else
            instanceid=$(aws ec2 run-instances --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 --instance-type t3.micro --key-name ping-test-key --region "$region" --query 'Instances[0].InstanceId' --output text)
        fi

        if [ -z $instanceid ]; then
            echo "--------------------run instance failed--------------------" # 如果instanceid为空，则表明新建失败，退出程序
            exit 1
        fi
        aws ec2 wait instance-status-ok --instance-ids "$instanceid" --region "$region" # 等待实例新建完成
        instanceip=$(aws ec2 describe-instances --instance-ids "$instanceid" --region "$region" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text) # 获取实例IP

        # 3. 修改安全组
        groupid=$(aws ec2 describe-instances --instance-ids "$instanceid" --region "$region" --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
        myip=$(curl icanhazip.com)
        aws ec2 authorize-security-group-ingress --group-id "$groupid" --protocol tcp --port 22 --cidr "$myip/32" --region "$region" # 只允许主控节点访问新建实例

        for i in $(seq 1 $time);
        do
            # 4. 登陆实例并Ping待测Ip
            echo "----------$i----------" >> "$ip"_"$region".txt
            ssh -o StrictHostKeyChecking=no -i ~/ping-test/id_rsa_test "$instanceip" "ping -c $pingcount $ip" >> "$ip"_"$region".txt # Ping结果保存到"$ip"_"$region".txt文件中

            # 5. 从Ping结果中筛选时延数据
            packetloss=$(tail -2 "$ip"_"$region".txt | head -1 | grep -E -o "([[:digit:]]+)%" | awk -F"%" '{print $1}')
            rttstring=$(tail -1 "$ip"_"$region".txt | grep -E -o "([[:digit:]]+\.[[:digit:]]+)+")
            # 将字符串转换成数组
            rttlist=($rttstring)
            min=${rttlist[0]}
            avg=${rttlist[1]}
            max=${rttlist[2]}
            mdev=${rttlist[3]}

            # 6. 上传时延数据
            metriclist="packetloss min avg max mdev"

            for i in $metriclist;
            do
                if [ $i == "packetloss" ]; then
                    aws cloudwatch put-metric-data --metric-name $i --namespace $namespace --unit Percent --value ${!i} --dimensions ipRegion="$ip"_"$region" # packetloss的单位是Percent，其他则是Milliseconds
                else
                    aws cloudwatch put-metric-data --metric-name $i --namespace $namespace --unit Milliseconds --value ${!i} --dimensions ipRegion="$ip"_"$region"
                fi

                if [ "$?" != 0 ]; then
                    echo "--------------------failed to put metric--------------------"
                fi
            done
        done

        # 7. 清空环境
        aws ec2 terminate-instances --instance-ids "$instanceid" --region "$region" # 删除实例
        aws ec2 wait instance-terminated --instance-ids "$instanceid" --region "$region" # 等待实例删除完成
        aws ec2 delete-key-pair --key-name "ping-test-key" --region "$region" # 删除导入的秘钥
        aws ec2 revoke-security-group-ingress --group-id "$groupid" --protocol tcp --port 22 --cidr "$myip/32" --region "$region" # 删除添加的安全组规则
        rm -rf ~/ping-test/ # 清空目录

        # 8. 将空值写入管道
        echo >&4
    )&
done

# 5. 等待并发任务结束
wait
exit 0
