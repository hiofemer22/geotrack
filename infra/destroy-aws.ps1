<#
  Elimina TODOS los recursos creados por deploy-aws.ps1 (EC2, IP elástica, RDS, SGs, llave).
  ATENCIÓN: borra la base de datos sin snapshot final. Pide confirmación antes de continuar.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $here '.deploy.json'
$s = Get-Content $stateFile -Raw | ConvertFrom-Json
$r = $s.region
if ((Read-Host "Escribe '$($s.project)' para borrar toda la infraestructura") -ne $s.project) { return }

aws ec2 terminate-instances --instance-ids $s.instanceId --region $r | Out-Null
aws rds delete-db-instance --db-instance-identifier "$($s.project)-db" --skip-final-snapshot --region $r | Out-Null
aws ec2 wait instance-terminated --instance-ids $s.instanceId --region $r
aws ec2 release-address --allocation-id $s.allocationId --region $r
aws ec2 delete-key-pair --key-name "$($s.project)-key" --region $r
aws rds wait db-instance-deleted --db-instance-identifier "$($s.project)-db" --region $r
aws ec2 delete-security-group --group-id $s.sgDb --region $r
aws ec2 delete-security-group --group-id $s.sgApi --region $r
Remove-Item $stateFile, $s.keyFile -Force
Write-Host 'Infraestructura eliminada.' -ForegroundColor Green
