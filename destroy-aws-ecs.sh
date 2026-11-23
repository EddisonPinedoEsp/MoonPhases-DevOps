#!/usr/bin/env bash
# Borra todo lo creado por deploy-aws-ecs.sh
set -uo pipefail
export AWS_DEFAULT_REGION=us-east-1
APP=moonphases
aws ecs update-service --cluster $APP --service $APP --desired-count 0 >/dev/null
aws ecs delete-service --cluster $APP --service $APP --force >/dev/null
echo "Esperando a que la task se detenga..."; sleep 60
aws ecs delete-cluster --cluster $APP >/dev/null && echo "Cluster borrado"
for r in frontend backend db; do aws ecr delete-repository --repository-name $APP-$r --force >/dev/null && echo "ECR $APP-$r borrado"; done
aws logs delete-log-group --log-group-name /ecs/$APP && echo "Log group borrado"
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$APP-ecs-sg --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 delete-security-group --group-id "$SG" && echo "Security group borrado"
