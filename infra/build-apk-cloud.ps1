<#
  Compila el APK de Android en una instancia EC2 Linux temporal y lo descarga.
  Útil cuando Windows (Smart App Control) bloquea las herramientas de Flutter.
  La instancia se termina al acabar (y se autodestruye a los 90 min como respaldo).
  Requiere infra\.deploy.json (usa la misma llave SSH y security group).
  Uso:  powershell -ExecutionPolicy Bypass -File infra\build-apk-cloud.ps1 [-Install]
#>
param(
  [string]$InstanceType = 'm7i-flex.large',   # 8 GB RAM, apta para el plan gratuito
  [string]$FlutterVersion = '3.47.6',
  [switch]$Install
)
$ErrorActionPreference = 'Continue'  # los avisos de ssh en stderr no son errores; se valida $LASTEXITCODE
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$s = Get-Content (Join-Path $here '.deploy.json') -Raw | ConvertFrom-Json
$Region = $s.region
# El keystore viaja dentro del paquete (mobile/android); sin él cada APK sale con otra firma
if (-not (Test-Path (Join-Path $root 'mobile\android\key.properties'))) {
  Write-Warning 'Falta mobile\android\key.properties: el APK se firmará con una clave temporal y habrá que desinstalar la app para actualizarla.'
}
function Aws { param([Parameter(ValueFromRemainingArguments)]$a) $out = & aws.exe @a --region $Region --output json; if ($LASTEXITCODE) { throw "aws $a falló" }; if ($out) { $out | ConvertFrom-Json } }

# El SG de la API ya permite SSH desde tu IP actual
$ami = (Aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id).Parameter.Value
Write-Host '==> Lanzando instancia de compilación' -ForegroundColor Cyan
$run = Aws ec2 run-instances --image-id $ami --instance-type $InstanceType --key-name "$($s.project)-key" `
  --security-group-ids $s.sgApi --instance-initiated-shutdown-behavior terminate `
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3,DeleteOnTermination=true}' `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$($s.project)-apk-builder},{Key=project,Value=$($s.project)}]"
$id = $run.Instances[0].InstanceId
try {
  & aws.exe ec2 wait instance-running --instance-ids $id --region $Region
  $ip = (Aws ec2 describe-instances --instance-ids $id).Reservations[0].Instances[0].PublicIpAddress
  $target = "ubuntu@$ip"
  $sshOpts = @('-i', $s.keyFile, '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'ConnectTimeout=8', '-o', 'ConnectionAttempts=15', '-o', 'ServerAliveInterval=15', '-o', 'LogLevel=ERROR')
  for ($i = 0; $i -lt 30; $i++) { ssh @sshOpts $target 'true' 2>$null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep 10 }

  Write-Host '==> Empaquetando proyecto móvil' -ForegroundColor Cyan
  $bundle = Join-Path $env:TEMP 'geotrack-mobile.tgz'
  tar -czf $bundle -C $root --exclude=mobile/build --exclude=mobile/.dart_tool --exclude=mobile/android/.gradle `
    --exclude=mobile/android/local.properties --exclude=mobile/.idea mobile
  scp @sshOpts $bundle "${target}:/tmp/mobile.tgz"

  Write-Host '==> Instalando Flutter + Android SDK y compilando (~15 min)' -ForegroundColor Cyan
  $script = @'
set -euo pipefail
sudo shutdown -h +90 >/dev/null 2>&1 || true
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq openjdk-17-jdk-headless unzip git xz-utils curl >/dev/null
export ANDROID_HOME=$HOME/android-sdk
mkdir -p $ANDROID_HOME/cmdline-tools
curl -fsSL -o /tmp/clt.zip https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip
unzip -q /tmp/clt.zip -d $ANDROID_HOME/cmdline-tools && mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest
export PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
yes | sdkmanager --licenses >/dev/null || true
sdkmanager "platform-tools" "platforms;android-37.0" "platforms;android-36" >/dev/null
ls $ANDROID_HOME/platforms
git clone -q --depth 1 -b __FLUTTER__ https://github.com/flutter/flutter.git $HOME/flutter
export PATH=$HOME/flutter/bin:$PATH
flutter config --no-analytics >/dev/null; flutter --disable-analytics >/dev/null || true
mkdir -p $HOME/src && tar -xzf /tmp/mobile.tgz -C $HOME/src
cd $HOME/src/mobile
sed -i 's/-Xmx8G -XX:MaxMetaspaceSize=4G/-Xmx4G -XX:MaxMetaspaceSize=1G/' android/gradle.properties
flutter pub get
BUILD="flutter build apk --release --dart-define=SERVER_URL=__SERVER__ --dart-define=DEVICE_API_KEY=__APIKEY__"
# Gradle puede autoinstalar componentes del SDK y no verlos hasta la siguiente ejecución: un reintento
$BUILD || $BUILD
ls -la build/app/outputs/flutter-apk/
'@.Replace('__FLUTTER__', $FlutterVersion).Replace('__SERVER__', "http://$($s.publicIp)").Replace('__APIKEY__', $s.deviceApiKey).Replace("`r`n", "`n")
  # Archivo con saltos LF y sin BOM (bash no tolera ninguno de los dos)
  $scriptFile = Join-Path $env:TEMP 'geotrack-build.sh'
  [IO.File]::WriteAllText($scriptFile, $script, (New-Object Text.UTF8Encoding $false))
  scp @sshOpts $scriptFile "${target}:/tmp/build.sh"
  ssh @sshOpts $target 'bash /tmp/build.sh'
  if ($LASTEXITCODE) { throw 'La compilación remota falló (ver salida arriba).' }

  $out = Join-Path $root 'mobile\build\app\outputs\flutter-apk'
  New-Item -ItemType Directory -Force $out | Out-Null
  scp @sshOpts "${target}:src/mobile/build/app/outputs/flutter-apk/app-release.apk" (Join-Path $out 'app-release.apk')
  if ($LASTEXITCODE) { throw 'No se pudo descargar el APK.' }
  Write-Host "==> APK: $out\app-release.apk" -ForegroundColor Green
}
finally {
  Write-Host '==> Terminando instancia de compilación' -ForegroundColor Cyan
  & aws.exe ec2 terminate-instances --instance-ids $id --region $Region | Out-Null
}

if ($Install) {
  $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
  & $adb install -r (Join-Path $out 'app-release.apk')
}
