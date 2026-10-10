$ErrorActionPreference = "Stop"

$script:CampusRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:DataRoot = Join-Path $script:CampusRoot ".local-data"
$script:UsersFile = Join-Path $script:DataRoot "users.json"
$script:Port = 8765
$script:Origin = "http://127.0.0.1:$($script:Port)"
$script:Sessions = @{}
$script:LoginFailures = @{}
$script:PasswordIterations = 310000
$script:SessionHours = 8

function ConvertTo-PlainText {
  param([System.Security.SecureString]$Value)
  $pointer = [IntPtr]::Zero
  try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
  }
  finally {
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
  }
}

function Get-PasswordHash {
  param([string]$Password, [byte[]]$Salt)
  $derive = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
    $Password,
    $Salt,
    $script:PasswordIterations,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256
  )
  try { return ,$derive.GetBytes(32) }
  finally { $derive.Dispose() }
}

function Initialize-LocalAdministrator {
  if (Test-Path -LiteralPath $script:UsersFile) { return }
  Write-Host "Primer inicio: crea la cuenta administradora local del campus." -ForegroundColor Cyan
  do {
    $email = (Read-Host "Correo de la cuenta administradora").Trim().ToLowerInvariant()
    if ($email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { Write-Host "Revisa el formato del correo." -ForegroundColor Yellow }
  } while ($email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$')

  do {
    $first = Read-Host "Crea una clave de al menos 12 caracteres" -AsSecureString
    $second = Read-Host "Confirma la clave" -AsSecureString
    $password = ConvertTo-PlainText $first
    $confirmation = ConvertTo-PlainText $second
    if ($password.Length -lt 12) { Write-Host "La clave necesita al menos 12 caracteres." -ForegroundColor Yellow }
    elseif ($password -cne $confirmation) { Write-Host "Las claves no coinciden." -ForegroundColor Yellow }
  } while ($password.Length -lt 12 -or $password -cne $confirmation)

  [void][System.IO.Directory]::CreateDirectory($script:DataRoot)
  $salt = New-Object byte[] 16
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($salt) }
  finally { $rng.Dispose() }
  $hash = Get-PasswordHash -Password $password -Salt $salt
  $user = [ordered]@{
    email = $email
    role = "admin"
    salt = [Convert]::ToBase64String($salt)
    passwordHash = [Convert]::ToBase64String($hash)
  }
  $database = [ordered]@{ users = @($user) }
  $json = ConvertTo-Json -InputObject $database -Depth 5
  [System.IO.File]::WriteAllText($script:UsersFile, $json, [System.Text.UTF8Encoding]::new($false))
  $password = $null
  $confirmation = $null
  Write-Host "Cuenta local creada. Sus datos quedan fuera del repositorio." -ForegroundColor Green
}

function Read-HttpRequest {
  param([System.IO.Stream]$Stream)
  $header = New-Object System.Text.StringBuilder
  $ending = ""
  while ($ending -ne "`r`n`r`n") {
    $character = $Stream.ReadByte()
    if ($character -lt 0) { return $null }
    [void]$header.Append([char]$character)
    if ($header.Length -gt 16384) { throw "Request headers too large." }
    $last = $header.ToString()
    if ($last.Length -ge 4) { $ending = $last.Substring($last.Length - 4) }
  }

  $lines = $header.ToString().TrimEnd("`r", "`n") -split "`r`n"
  $requestLine = $lines[0] -split " ", 3
  if ($requestLine.Length -lt 2) { throw "Invalid request line." }
  $headers = @{}
  foreach ($line in $lines | Select-Object -Skip 1) {
    $separator = $line.IndexOf(":")
    if ($separator -gt 0) { $headers[$line.Substring(0, $separator).Trim().ToLowerInvariant()] = $line.Substring($separator + 1).Trim() }
  }
  $length = 0
  if ($headers.ContainsKey("content-length")) {
    if (-not [int]::TryParse($headers["content-length"], [ref]$length) -or $length -lt 0 -or $length -gt 16384) { throw "Invalid request body length." }
  }
  $body = New-Object byte[] $length
  $offset = 0
  while ($offset -lt $length) {
    $read = $Stream.Read($body, $offset, $length - $offset)
    if ($read -le 0) { throw "Incomplete request body." }
    $offset += $read
  }
  return @{
    Method = $requestLine[0].ToUpperInvariant()
    Target = $requestLine[1]
    Headers = $headers
    Body = [System.Text.Encoding]::UTF8.GetString($body)
  }
}

function Send-Response {
  param(
    [System.IO.Stream]$Stream,
    [int]$Status,
    [string]$ContentType = "text/plain; charset=utf-8",
    [byte[]]$Body = @(),
    [string[]]$ExtraHeaders = @()
  )
  $statusText = switch ($Status) {
    200 { "OK" } 302 { "Found" } 400 { "Bad Request" } 401 { "Unauthorized" }
    403 { "Forbidden" } 404 { "Not Found" } 405 { "Method Not Allowed" }
    413 { "Payload Too Large" } 429 { "Too Many Requests" } default { "Internal Server Error" }
  }
  $headers = @(
    "HTTP/1.1 $Status $statusText",
    "Content-Type: $ContentType",
    "Content-Length: $($Body.Length)",
    "Connection: close",
    "X-Content-Type-Options: nosniff",
    "X-Frame-Options: SAMEORIGIN",
    "Referrer-Policy: same-origin",
    "Cache-Control: no-store"
  ) + $ExtraHeaders + @("", "")
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n"))
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
  $Stream.Flush()
}

function Send-Json {
  param([System.IO.Stream]$Stream, [int]$Status, [object]$Value, [string[]]$ExtraHeaders = @())
  $json = ConvertTo-Json -InputObject $Value -Compress -Depth 6
  $body = [System.Text.Encoding]::UTF8.GetBytes($json)
  Send-Response -Stream $Stream -Status $Status -ContentType "application/json; charset=utf-8" -Body $body -ExtraHeaders $ExtraHeaders
}

function Get-RequestCookie {
  param([hashtable]$Headers, [string]$Name)
  if (-not $Headers.ContainsKey("cookie")) { return "" }
  foreach ($part in $Headers["cookie"].Split(";")) {
    $pair = $part.Trim().Split("=", 2)
    if ($pair.Length -eq 2 -and $pair[0] -eq $Name) { return $pair[1] }
  }
  return ""
}

function Get-Session {
  param([hashtable]$Headers)
  $token = Get-RequestCookie -Headers $Headers -Name "minex_local_session"
  if (-not $token -or -not $script:Sessions.ContainsKey($token)) { return $null }
  $session = $script:Sessions[$token]
  if ([DateTime]::UtcNow -ge $session.expiresAt) {
    $script:Sessions.Remove($token)
    return $null
  }
  return $session
}

function Test-SameOrigin {
  param([hashtable]$Headers)
  return $Headers.ContainsKey("origin") -and $Headers["origin"] -eq $script:Origin
}

function Get-UserDatabase {
  return (Get-Content -LiteralPath $script:UsersFile -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-UserDatabase {
  param([object[]]$Users)
  $json = ConvertTo-Json -InputObject ([ordered]@{ users = @($Users) }) -Depth 6
  $temporaryFile = "$($script:UsersFile).tmp"
  [System.IO.File]::WriteAllText($temporaryFile, $json, [System.Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $temporaryFile -Destination $script:UsersFile -Force
}

function Test-Password {
  param([string]$Password, [string]$SaltText, [string]$HashText)
  try {
    $salt = [Convert]::FromBase64String($SaltText)
    $expected = [Convert]::FromBase64String($HashText)
    $actual = Get-PasswordHash -Password $Password -Salt $salt
    if ($actual.Length -ne $expected.Length) { return $false }
    $difference = 0
    for ($index = 0; $index -lt $actual.Length; $index++) { $difference = $difference -bor ($actual[$index] -bxor $expected[$index]) }
    return $difference -eq 0
  }
  catch { return $false }
}

function New-SessionToken {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) }
  finally { $rng.Dispose() }
  return [Convert]::ToBase64String($bytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
}

function Get-ContentType {
  param([string]$Extension)
  switch ($Extension.ToLowerInvariant()) {
    ".html" { "text/html; charset=utf-8" } ".css" { "text/css; charset=utf-8" }
    ".js" { "text/javascript; charset=utf-8" } ".svg" { "image/svg+xml" }
    ".png" { "image/png" } ".jpg" { "image/jpeg" } ".jpeg" { "image/jpeg" }
    ".webp" { "image/webp" } ".ico" { "image/x-icon" } default { "application/octet-stream" }
  }
}

function Handle-Request {
  param([System.IO.Stream]$Stream, [string]$ClientAddress)
  $request = Read-HttpRequest -Stream $Stream
  if ($null -eq $request) { return }
  if (-not $request.Headers.ContainsKey("host") -or $request.Headers["host"] -ne "127.0.0.1:$($script:Port)" -or -not $request.Target.StartsWith("/")) {
    Send-Response $Stream 403
    return
  }
  $uri = [System.Uri]::new([System.Uri]$script:Origin, $request.Target)
  $path = [System.Uri]::UnescapeDataString($uri.AbsolutePath)
  if ($path -eq "/") { $path = "/index.html" }

  if ($request.Method -eq "GET" -and $path -eq "/api/auth/session") {
    $session = Get-Session -Headers $request.Headers
    if ($session) { Send-Json $Stream 200 @{ authenticated = $true; email = $session.email; role = $session.role } }
    else { Send-Json $Stream 200 @{ authenticated = $false } }
    return
  }

  if ($path -eq "/api/admin/users") {
    $adminSession = Get-Session -Headers $request.Headers
    if (-not $adminSession -or $adminSession.role -ne "admin") { Send-Json $Stream 403 @{ message = "Se requiere una cuenta administradora." }; return }
    if ($request.Method -eq "GET") {
      $database = Get-UserDatabase
      $publicUsers = @($database.users | ForEach-Object { @{ email = $_.email; role = $_.role } })
      Send-Json $Stream 200 @{ users = $publicUsers }
      return
    }
    if ($request.Method -ne "POST") { Send-Json $Stream 405 @{ message = "Verbo no permitido." }; return }
    if (-not (Test-SameOrigin $request.Headers)) { Send-Json $Stream 403 @{ message = "Origen de solicitud no permitido." }; return }
    try { $input = $request.Body | ConvertFrom-Json }
    catch { Send-Json $Stream 400 @{ message = "No fue posible leer los datos de la cuenta." }; return }
    $email = ([string]$input.email).Trim().ToLowerInvariant()
    $password = [string]$input.password
    if ($email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$' -or $email.Length -gt 254) { Send-Json $Stream 400 @{ message = "Revisa el formato del correo." }; return }
    if ($password.Length -lt 12 -or $password.Length -gt 128) { Send-Json $Stream 400 @{ message = "La clave debe tener entre 12 y 128 caracteres." }; return }
    $database = Get-UserDatabase
    $users = @($database.users)
    $existingUser = $users | Where-Object { $_.email -eq $email } | Select-Object -First 1
    if ($existingUser) { Send-Json $Stream 409 @{ message = "Ya existe una cuenta con ese correo." }; return }
    $salt = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($salt) }
    finally { $rng.Dispose() }
    $hash = Get-PasswordHash -Password $password -Salt $salt
    $users += [ordered]@{ email = $email; role = "user"; salt = [Convert]::ToBase64String($salt); passwordHash = [Convert]::ToBase64String($hash) }
    try { Save-UserDatabase -Users $users }
    catch { Send-Json $Stream 500 @{ message = "No fue posible guardar la cuenta local." }; return }
    Send-Json $Stream 201 @{ user = @{ email = $email; role = "user" } }
    return
  }

  if ($request.Method -eq "POST" -and $path -eq "/api/auth/login") {
    if (-not (Test-SameOrigin $request.Headers)) { Send-Json $Stream 403 @{ message = "Origen de solicitud no permitido." }; return }
    $now = [DateTime]::UtcNow
    $attempt = $script:LoginFailures[$ClientAddress]
    if ($attempt -and $attempt.startedAt -gt $now.AddMinutes(-15) -and $attempt.count -ge 5) {
      Send-Json $Stream 429 @{ message = "Demasiados intentos. Espera 15 minutos antes de volver a ingresar." }
      return
    }
    try { $input = $request.Body | ConvertFrom-Json }
    catch { Send-Json $Stream 400 @{ message = "No fue posible leer los datos de acceso." }; return }
    $email = ([string]$input.email).Trim().ToLowerInvariant()
    $password = [string]$input.password
    $database = Get-UserDatabase
    $user = @($database.users | Where-Object { $_.email -eq $email }) | Select-Object -First 1
    if ($user) { $validPassword = Test-Password -Password $password -SaltText $user.salt -HashText $user.passwordHash }
    else { $validPassword = Test-Password -Password $password -SaltText $script:DummySaltText -HashText $script:DummyHash }
    $password = $null
    if (-not $user -or -not $validPassword) {
      if (-not $attempt -or $attempt.startedAt -le $now.AddMinutes(-15)) { $attempt = @{ count = 0; startedAt = $now } }
      $attempt.count++
      $script:LoginFailures[$ClientAddress] = $attempt
      Send-Json $Stream 401 @{ message = "Correo o clave incorrectos." }
      return
    }
    $script:LoginFailures.Remove($ClientAddress)
    $token = New-SessionToken
    $script:Sessions[$token] = @{ email = $user.email; role = $user.role; expiresAt = $now.AddHours($script:SessionHours) }
    $cookie = "Set-Cookie: minex_local_session=$token; Path=/; HttpOnly; SameSite=Strict; Max-Age=$($script:SessionHours * 3600)"
    Send-Json $Stream 200 @{ authenticated = $true; email = $user.email; role = $user.role } @($cookie)
    return
  }

  if ($request.Method -eq "POST" -and $path -eq "/api/auth/logout") {
    if (-not (Test-SameOrigin $request.Headers)) { Send-Json $Stream 403 @{ message = "Origen de solicitud no permitido." }; return }
    $token = Get-RequestCookie -Headers $request.Headers -Name "minex_local_session"
    if ($token) { $script:Sessions.Remove($token) }
    $expired = "Set-Cookie: minex_local_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
    Send-Json $Stream 200 @{ authenticated = $false } @($expired)
    return
  }

  if ($path -like "/api/*") { Send-Json $Stream 404 @{ message = "Recurso no encontrado." }; return }
  if ($request.Method -ne "GET") { Send-Response $Stream 405; return }

  $session = Get-Session -Headers $request.Headers
  $privatePage = $path -in @("/index.html", "/ruta-capacitaciones.html", "/curso.html", "/curso-induccion.html", "/admin.html") -or $path.StartsWith("/assets/", [StringComparison]::OrdinalIgnoreCase)
  if ($privatePage -and -not $session) {
    $returnUrl = [Uri]::EscapeDataString("$($uri.AbsolutePath)$($uri.Query)")
    Send-Response $Stream 302 -ExtraHeaders @("Location: /login.html?returnUrl=$returnUrl")
    return
  }
  if ($path -eq "/admin.html" -and $session.role -ne "admin") { Send-Response $Stream 403; return }
  if ($path -match '^/(?:\.local-data|dev-server\.ps1|README\.md)(?:/|$)') { Send-Response $Stream 404; return }

  $relative = $path.TrimStart("/").Replace("/", [System.IO.Path]::DirectorySeparatorChar)
  $fullPath = [System.IO.Path]::GetFullPath((Join-Path $script:CampusRoot $relative))
  $rootPrefix = $script:CampusRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    Send-Response $Stream 404
    return
  }
  $extension = [System.IO.Path]::GetExtension($fullPath)
  if ($extension -notin @(".html", ".css", ".js", ".svg", ".png", ".jpg", ".jpeg", ".webp", ".ico")) { Send-Response $Stream 404; return }
  $file = [System.IO.File]::ReadAllBytes($fullPath)
  $extra = @()
  if ($privatePage) { $extra += "Vary: Cookie" }
  Send-Response -Stream $Stream -Status 200 -ContentType (Get-ContentType $extension) -Body $file -ExtraHeaders $extra
}

Initialize-LocalAdministrator
$script:DummySalt = New-Object byte[] 16
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($script:DummySalt) }
finally { $rng.Dispose() }
$script:DummySaltText = [Convert]::ToBase64String($script:DummySalt)
$script:DummyHash = [Convert]::ToBase64String((Get-PasswordHash -Password "invalid-local-login" -Salt $script:DummySalt))
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $script:Port)
$listener.Start()
Write-Host "Campus local disponible en $($script:Origin)" -ForegroundColor Green
Write-Host "Solo acepta conexiones de este equipo. Presiona Ctrl+C para detenerlo." -ForegroundColor DarkGray

try {
  while ($true) {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 10000
    $client.SendTimeout = 10000
    $stream = $client.GetStream()
    try {
      $address = $client.Client.RemoteEndPoint.Address.ToString()
      if ($address -eq "127.0.0.1") { Handle-Request -Stream $stream -ClientAddress $address }
      else { Send-Response -Stream $stream -Status 403 }
    }
    catch {
      try { Send-Response -Stream $stream -Status 400 } catch { }
    }
    finally {
      $stream.Dispose()
      $client.Close()
    }
  }
}
finally {
  $listener.Stop()
  $script:Sessions.Clear()
  Write-Host "Servidor local detenido." -ForegroundColor DarkGray
}
