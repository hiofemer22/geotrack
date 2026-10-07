<#
  Crea la infraestructura de GeoTrack en AWS (una sola vez):
    - Security groups (API y base de datos)
    - RDS PostgreSQL 16 (db.t4g.micro, privada, cifrada, backups 7 días)
    - EC2 Amazon Linux 2023 (t3.small) con Node.js + Nginx + IP elástica
  y luego despliega la aplicación con update-app.ps1.

  Requisitos: AWS CLI configurada (aws configure) y OpenSSH (incluido en Windows 10/11).
  Uso:  powershell -ExecutionPolicy Bypass -File infra\deploy-aws.ps1 -Region us-east-1
#>
param(
  [string]$Region = 'us-east-1',
  [string]$Project = 'geotrack',
  [string]$InstanceType = 't3.small',
  [string]$DbClass = 'db.t4g.micro'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $here '.deploy.json'
if (Test-Path $stateFile) { throw "Ya existe $stateFile. Para actualizar el código usa infra\update-app.ps1" }

function Aws { param([Parameter(ValueFromRemainingArguments)]$a) $out = & aws.exe @a --region $Region --output json; if ($LASTEXITCODE) { throw "aws $a falló" }; if ($out) { $out | ConvertFrom-Json } }
function Secret([int]$n = 32) { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count $n | ForEach-Object { [char]$_ }) }

Write-Host '==> Cuenta AWS' -ForegroundColor Cyan
$who = Aws sts get-caller-identity
Write-Host "    $($who.Arn)"

$vpcId = (Aws ec2 describe-vpcs --filters 'Name=isDefault,Values=true').Vpcs[0].VpcId
if (-not $vpcId) { throw 'No hay VPC por defecto en la región.' }
$myIp = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()

Write-Host '==> Security groups' -ForegroundColor Cyan
function ExistingSg($name) { (Aws ec2 describe-security-groups --filters "Name=group-name,Values=$name" "Name=vpc-id,Values=$vpcId").SecurityGroups | Select-Object -First 1 -Expand GroupId }
# Reutiliza los SG si un intento anterior ya los creó
$sgApi = ExistingSg "$Project-api"
if (-not $sgApi) {
  $sgApi = (Aws ec2 create-security-group --group-name "$Project-api" --description 'GeoTrack API' --vpc-id $vpcId).GroupId
  Aws ec2 authorize-security-group-ingress --group-id $sgApi --ip-permissions `
    "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$myIp/32,Description=SSH-admin}]" `
    'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' `
    'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' | Out-Null
}
$sgDb = ExistingSg "$Project-db"
if (-not $sgDb) {
  $sgDb = (Aws ec2 create-security-group --group-name "$Project-db" --description 'GeoTrack DB' --vpc-id $vpcId).GroupId
  Aws ec2 authorize-security-group-ingress --group-id $sgDb --ip-permissions `
    "IpProtocol=tcp,FromPort=5432,ToPort=5432,UserIdGroupPairs=[{GroupId=$sgApi}]" | Out-Null
}

Write-Host '==> RDS PostgreSQL (tarda ~10 min)' -ForegroundColor Cyan
$dbPassword = Secret 28
Aws rds create-db-instance --db-instance-identifier "$Project-db" --engine postgres --engine-version 16 `
  --db-instance-class $DbClass --allocated-storage 20 --storage-type gp2 --storage-encrypted `
  --master-username geotrack --master-user-password $dbPassword --db-name geotrack `
  --vpc-security-group-ids $sgDb --no-publicly-accessible --backup-retention-period 1 `
  --tags "Key=project,Value=$Project" | Out-Null

Write-Host '==> Par de llaves SSH' -ForegroundColor Cyan
$keyFile = Join-Path $here "$Project-key.pem"
$key = Aws ec2 create-key-pair --key-name "$Project-key" --key-type ed25519
Set-Content -Path $keyFile -Value $key.KeyMaterial -NoNewline -Encoding ascii
icacls $keyFile /inheritance:r /grant:r "$($env:USERNAME):(R)" | Out-Null

Write-Host '==> Instancia EC2' -ForegroundColor Cyan
$ami = (Aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64).Parameter.Value
$userData = Join-Path $here 'user-data.sh'
$run = Aws ec2 run-instances --image-id $ami --instance-type $InstanceType --key-name "$Project-key" `
  --security-group-ids $sgApi --user-data "file://$userData" `
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true}' `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Project-api},{Key=project,Value=$Project}]"
$instanceId = $run.Instances[0].InstanceId
& aws.exe ec2 wait instance-running --instance-ids $instanceId --region $Region
$eip = Aws ec2 allocate-address --domain vpc
Aws ec2 associate-address --instance-id $instanceId --allocation-id $eip.AllocationId | Out-Null

Write-Host '==> Esperando a que RDS esté disponible…' -ForegroundColor Cyan
& aws.exe rds wait db-instance-available --db-instance-identifier "$Project-db" --region $Region
$dbHost = (Aws rds describe-db-instances --db-instance-identifier "$Project-db").DBInstances[0].Endpoint.Address

$state = [ordered]@{
  region = $Region; project = $Project; instanceId = $instanceId; publicIp = $eip.PublicIp
  allocationId = $eip.AllocationId; sgApi = $sgApi; sgDb = $sgDb; keyFile = $keyFile
  databaseUrl = "postgres://geotrack:$dbPassword@${dbHost}:5432/geotrack"
  deviceApiKey = Secret 32; dashboardToken = Secret 32
}
$state | ConvertTo-Json | Set-Content $stateFile -Encoding utf8

& (Join-Path $here 'update-app.ps1')

Write-Host ''
Write-Host '==================== LISTO ====================' -ForegroundColor Green
Write-Host "Dashboard:        http://$($eip.PublicIp)"
Write-Host "URL para la app:  http://$($eip.PublicIp)"
Write-Host "Token dashboard y API key del dispositivo: ver infra\.deploy.json (no lo compartas)"
