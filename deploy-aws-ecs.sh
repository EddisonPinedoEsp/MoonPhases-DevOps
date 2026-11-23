#!/usr/bin/env bash
# Despliegue de MoonPhases en AWS con ECR + ECS Fargate (mismo patrón del Lab 14.2).
# Ejecutar desde la raíz del repo MoonPhases-DevOps, en WSL, con Docker Desktop abierto.
set -euo pipefail

REGION=us-east-1
APP=moonphases
ACC=$(aws sts get-caller-identity --query Account --output text)
REG=$ACC.dkr.ecr.$REGION.amazonaws.com
export AWS_DEFAULT_REGION=$REGION
# Puerto de Nginx tomado del propio nginx.conf (8080 en main, 8081 en la rama devsecops)
WEB_PORT=$(grep -oE "listen[[:space:]]+[0-9]+" frontend/nginx.conf | grep -oE "[0-9]+" | head -1)
echo "Puerto del frontend: $WEB_PORT"

echo "== 1. Repositorios ECR"
for r in frontend backend db; do
  aws ecr create-repository --repository-name $APP-$r >/dev/null 2>&1 || true
done
aws ecr get-login-password | docker login --username AWS --password-stdin "$REG"

echo "== 2. Ajustes para ECS (en una task Fargate los contenedores comparten localhost)"
sed -i 's#proxy_pass http://backend:3001;#proxy_pass http://127.0.0.1:3001;#' frontend/nginx.conf
printf 'FROM postgres:16.3-alpine\nCOPY schema.sql /docker-entrypoint-initdb.d/schema.sql\n' > backend/db/Dockerfile

echo "== 3. Build y push de las 3 imágenes"
docker build -t "$REG/$APP-frontend:latest" frontend
docker build -t "$REG/$APP-backend:latest"  backend
docker build -t "$REG/$APP-db:latest"       backend/db
for r in frontend backend db; do docker push "$REG/$APP-$r:latest"; done

echo "== 4. Rol de ejecución, clúster y logs"
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null 2>&1 || true
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws ecs create-cluster --cluster-name $APP >/dev/null
aws logs create-log-group --log-group-name /ecs/$APP >/dev/null 2>&1 || true
sleep 10   # el rol IAM recién creado tarda unos segundos en propagarse

echo "== 5. Task definition (frontend + backend + postgres en la misma task)"
PW=$(openssl rand -hex 16)
LOG='"logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/'$APP'","awslogs-region":"'$REGION'","awslogs-stream-prefix":"'$APP'"}}'
cat > /tmp/taskdef.json <<JSON
{
  "family": "$APP",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048",
  "executionRoleArn": "arn:aws:iam::$ACC:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "postgres",
      "image": "$REG/$APP-db:latest",
      "essential": true,
      "environment": [
        {"name":"POSTGRES_USER","value":"moonuser"},
        {"name":"POSTGRES_DB","value":"moonphases_db"},
        {"name":"POSTGRES_PASSWORD","value":"$PW"}
      ],
      "healthCheck": {"command":["CMD-SHELL","pg_isready -U moonuser -d moonphases_db"],"interval":5,"timeout":5,"retries":10,"startPeriod":10},
      $LOG
    },
    {
      "name": "backend",
      "image": "$REG/$APP-backend:latest",
      "essential": true,
      "environment": [
        {"name":"PORT","value":"3001"},
        {"name":"DB_HOST","value":"127.0.0.1"},
        {"name":"DB_PORT","value":"5432"},
        {"name":"DB_USER","value":"moonuser"},
        {"name":"DB_NAME","value":"moonphases_db"},
        {"name":"DB_PASSWORD","value":"$PW"}
      ],
      "dependsOn": [{"containerName":"postgres","condition":"HEALTHY"}],
      $LOG
    },
    {
      "name": "frontend",
      "image": "$REG/$APP-frontend:latest",
      "essential": true,
      "portMappings": [{"containerPort":$WEB_PORT,"protocol":"tcp"}],
      "dependsOn": [{"containerName":"backend","condition":"START"}],
      $LOG
    }
  ]
}
JSON
aws ecs register-task-definition --cli-input-json file:///tmp/taskdef.json >/dev/null

echo "== 6. Red: VPC por defecto + Security Group con el puerto del frontend"
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$APP-ecs-sg Name=vpc-id,Values=$VPC --query 'SecurityGroups[0].GroupId' --output text)
if [ "$SG" = "None" ]; then
  SG=$(aws ec2 create-security-group --group-name $APP-ecs-sg --description "MoonPhases ECS" --vpc-id $VPC --query GroupId --output text)
  aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port $WEB_PORT --cidr 0.0.0.0/0 >/dev/null
fi

echo "== 7. Servicio ECS Fargate"
aws ecs create-service --cluster $APP --service-name $APP --task-definition $APP --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=ENABLED}" >/dev/null

echo "== 8. Esperando la IP pública de la task..."
for i in $(seq 1 40); do
  TASK=$(aws ecs list-tasks --cluster $APP --service-name $APP --query 'taskArns[0]' --output text)
  if [ "$TASK" != "None" ]; then
    ENI=$(aws ecs describe-tasks --cluster $APP --tasks "$TASK" --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text)
    if [ -n "$ENI" ] && [ "$ENI" != "None" ]; then
      IP=$(aws ec2 describe-network-interfaces --network-interface-ids "$ENI" --query 'NetworkInterfaces[0].Association.PublicIp' --output text)
      [ "$IP" != "None" ] && break
    fi
  fi
  sleep 6
done
echo
echo "App:    http://$IP:$WEB_PORT/MoonPhases/"
echo "Health: http://$IP:$WEB_PORT/api/health"
echo "(los contenedores tardan 1-2 min más en quedar RUNNING)"
