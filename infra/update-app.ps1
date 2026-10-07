<#
  Compila el dashboard, empaqueta el backend y lo despliega en la instancia EC2.
  Úsalo cada vez que cambies código:  powershell -ExecutionPolicy Bypass -File infra\update-app.ps1
#>
$ErrorActionPreference = 'Continue'  # los avisos de ssh/npm en stderr no son errores; se valida $LASTEXITCODE
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$s = Get-Content (Join-Path $here '.deploy.json') -Raw | ConvertFrom-Json
$target = "ec2-user@$($s.publicIp)"
$sshOpts = @('-i', $s.keyFile, '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=15', '-o', 'ServerAliveInterval=15', '-o', 'LogLevel=ERROR')

Write-Host '==> Compilando dashboard web' -ForegroundColor Cyan
Push-Location (Join-Path $root 'web'); npm install --no-audit --no-fund; npm run build; Pop-Location

Write-Host '==> Empaquetando backend' -ForegroundColor Cyan
$bundle = Join-Path $env:TEMP 'geotrack-backend.tgz'
tar -czf $bundle -C (Join-Path $root 'backend') src public package.json package-lock.json

$envFile = Join-Path $env:TEMP 'geotrack.env'
@"
PORT=8080
DATABASE_URL=$($s.databaseUrl)
DB_SSL=true
DEVICE_API_KEY=$($s.deviceApiKey)
DASHBOARD_TOKEN=$($s.dashboardToken)
OFFLINE_AFTER_SEC=120
"@ | Set-Content $envFile -Encoding ascii -NoNewline

Write-Host '==> Esperando a que la instancia termine su configuración inicial' -ForegroundColor Cyan
for ($i = 0; $i -lt 60; $i++) {
  ssh @sshOpts $target 'test -f /opt/geotrack/ready' 2>$null
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep 10
}

Write-Host '==> Subiendo y reiniciando servicio' -ForegroundColor Cyan
scp @sshOpts $bundle "${target}:/tmp/app.tgz"
scp @sshOpts $envFile "${target}:/tmp/app.env"
Remove-Item $envFile
ssh @sshOpts $target @'
set -e
sudo rm -rf /opt/geotrack/app.new && sudo mkdir -p /opt/geotrack/app.new
sudo tar -xzf /tmp/app.tgz -C /opt/geotrack/app.new
sudo mv /tmp/app.env /opt/geotrack/app.new/.env
cd /opt/geotrack/app.new && sudo npm ci --omit=dev --no-audit --no-fund
sudo rm -rf /opt/geotrack/app.old; [ -d /opt/geotrack/app ] && sudo mv /opt/geotrack/app /opt/geotrack/app.old
sudo mv /opt/geotrack/app.new /opt/geotrack/app
sudo chown -R geotrack:geotrack /opt/geotrack/app && sudo chmod 600 /opt/geotrack/app/.env
sudo systemctl restart geotrack
sleep 3
curl -fsS http://127.0.0.1/api/health
'@
if ($LASTEXITCODE) { throw 'El despliegue falló. Revisa: ssh ... sudo journalctl -u geotrack -n 50' }
Write-Host "`n==> Desplegado en http://$($s.publicIp)" -ForegroundColor Green
