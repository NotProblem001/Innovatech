#!/bin/bash
set -e

REGION="us-east-1"
AMI_ID="ami-0c7217cdde317cfec" # Ubuntu 22.04
INSTANCE_TYPE="t3.micro"
# Prefijo para nombrar recursos
PREFIX="innovatech"

echo "=== 1. Creando VPC (10.0.0.0/16) ==="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PREFIX-vpc" --query "Vpcs[0].VpcId" --output text)
if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
  aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$PREFIX-vpc
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames "{\"Value\":true}"
fi

echo "=== 2. Creando Subredes (Pública y Privada) ==="
# Subred Pública (Frontend)
PUB_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$PREFIX-public-subnet" --query "Subnets[0].SubnetId" --output text)
if [ "$PUB_SUBNET_ID" == "None" ] || [ -z "$PUB_SUBNET_ID" ]; then
  PUB_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources $PUB_SUBNET_ID --tags Key=Name,Value=$PREFIX-public-subnet
  aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_ID --map-public-ip-on-launch "{\"Value\":true}"
fi

# Subred Privada (Backend y DB)
PRIV_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$PREFIX-private-subnet" --query "Subnets[0].SubnetId" --output text)
if [ "$PRIV_SUBNET_ID" == "None" ] || [ -z "$PRIV_SUBNET_ID" ]; then
  PRIV_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone ${REGION}a --query 'Subnet.SubnetId' --output text)
  aws ec2 create-tags --resources $PRIV_SUBNET_ID --tags Key=Name,Value=$PREFIX-private-subnet
fi

echo "=== 3. Configurando Enrutamiento (IGW y NAT) ==="
# Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query "InternetGateways[0].InternetGatewayId" --output text)
if [ "$IGW_ID" == "None" ] || [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
  aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
  
  # Tabla de ruteo pública
  PUB_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id $PUB_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
  aws ec2 associate-route-table --subnet-id $PUB_SUBNET_ID --route-table-id $PUB_RT_ID
  aws ec2 create-tags --resources $PUB_RT_ID --tags Key=Name,Value=$PREFIX-public-rt
fi

# NAT Gateway (Para que Backend y DB tengan internet)
NAT_GW_ID=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available,pending" --query "NatGateways[0].NatGatewayId" --output text)
if [ "$NAT_GW_ID" == "None" ] || [ -z "$NAT_GW_ID" ]; then
  echo "Creando EIP y NAT Gateway (Esto toma unos minutos)..."
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
  NAT_GW_ID=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_ID --allocation-id $EIP_ALLOC --query 'NatGateway.NatGatewayId' --output text)
  aws ec2 create-tags --resources $NAT_GW_ID --tags Key=Name,Value=$PREFIX-nat
  aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW_ID
  
  # Tabla de ruteo privada
  PRIV_RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
  aws ec2 create-route --route-table-id $PRIV_RT_ID --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW_ID
  aws ec2 associate-route-table --subnet-id $PRIV_SUBNET_ID --route-table-id $PRIV_RT_ID
  aws ec2 create-tags --resources $PRIV_RT_ID --tags Key=Name,Value=$PREFIX-private-rt
fi

echo "=== 4. Creando Security Groups ==="
# SG Frontend (Público)
FRONT_SG_ID=$(aws ec2 create-security-group --group-name $PREFIX-frontend-sg --description "SG Frontend" --vpc-id $VPC_ID --query 'GroupId' --output text 2>/dev/null || aws ec2 describe-security-groups --filters "Name=group-name,Values=$PREFIX-frontend-sg" --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $FRONT_SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $FRONT_SG_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $FRONT_SG_ID --protocol icmp --port -1 --cidr 0.0.0.0/0 2>/dev/null || true # Para pruebas de Ping

# SG Backend (Privado, solo acepta de Frontend)
BACK_SG_ID=$(aws ec2 create-security-group --group-name $PREFIX-backend-sg --description "SG Backend" --vpc-id $VPC_ID --query 'GroupId' --output text 2>/dev/null || aws ec2 describe-security-groups --filters "Name=group-name,Values=$PREFIX-backend-sg" --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $BACK_SG_ID --protocol tcp --port 8080 --source-group $FRONT_SG_ID 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $BACK_SG_ID --protocol icmp --port -1 --source-group $FRONT_SG_ID 2>/dev/null || true

# SG Data (Privado, solo acepta de Backend)
DATA_SG_ID=$(aws ec2 create-security-group --group-name $PREFIX-data-sg --description "SG Data" --vpc-id $VPC_ID --query 'GroupId' --output text 2>/dev/null || aws ec2 describe-security-groups --filters "Name=group-name,Values=$PREFIX-data-sg" --query "SecurityGroups[0].GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $DATA_SG_ID --protocol tcp --port 3306 --source-group $BACK_SG_ID 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id $DATA_SG_ID --protocol icmp --port -1 --source-group $BACK_SG_ID 2>/dev/null || true


echo "=== 6. Creando Instancias EC2 ==="
cat <<EOF > user_data.sh
#!/bin/bash
apt-get update -y
apt-get install -y docker.io unzip curl git
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu
EOF

get_or_create_ec2() {
  local name=$1
  local subnet=$2
  local sg=$3
  local public_ip=$4
  
  local id=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$name" "Name=instance-state-name,Values=running,pending" --query "Reservations[0].Instances[0].InstanceId" --output text)
  if [ "$id" == "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 run-instances \
      --image-id $AMI_ID \
      --count 1 \
      --instance-type $INSTANCE_TYPE \
      --subnet-id $subnet \
      --security-group-ids $sg \
      --iam-instance-profile Name=LabInstanceProfile \
      --key-name vockey \
      $public_ip \
      --user-data file://user_data.sh \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
      --query 'Instances[0].InstanceId' \
      --output text)
  fi
  echo "$id"
}

# Frontend en Subred Pública
FRONTEND_EC2=$(get_or_create_ec2 "$PREFIX-frontend" $PUB_SUBNET_ID $FRONT_SG_ID "--associate-public-ip-address")

# Backend y Data en Subred Privada (SIN IP PÚBLICA)
BACKEND_EC2=$(get_or_create_ec2 "$PREFIX-backend" $PRIV_SUBNET_ID $BACK_SG_ID "--no-associate-public-ip-address")
DB_EC2=$(get_or_create_ec2 "$PREFIX-db" $PRIV_SUBNET_ID $DATA_SG_ID "--no-associate-public-ip-address")

rm -f user_data.sh
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

echo "--------------------------------------------------------"
echo " ¡INFRAESTRUCTURA INNOVATECH CREADA CON ÉXITO!"
echo "--------------------------------------------------------"
echo "VPC_ID                   : $VPC_ID"
echo "EC2_FRONTEND (Pública)   : $FRONTEND_EC2"
echo "EC2_BACKEND  (Privada)   : $BACKEND_EC2"
echo "EC2_DB       (Privada)   : $DB_EC2"
echo "ECR_REGISTRY             : $AWS_ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
echo "--------------------------------------------------------"