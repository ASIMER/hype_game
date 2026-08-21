# One-time Windows Firewall setup for Hype Raiders — kills the "Windows Security
# wants to allow this app" prompt that reappears for EVERY new build exe.
#
# WHY it kept asking: each export goes to a NEW timestamped folder, so every build
# is a brand-new program path to the firewall; hosting binds UDP 24565 (ENet) +
# 24566 (LAN discovery) -> per-exe prompt each time. PORT-scoped allow rules cover
# ANY exe on those ports, so new builds (and the Godot editor / --agent runs)
# never prompt again.
#
# Run:  pwsh tools\build\allow_firewall.ps1   (self-elevates via UAC)

$rules = @(
	@{ Name = "Hype Raiders (game+discovery UDP)"; Proto = "UDP"; Ports = "24565-24566" },
	@{ Name = "Hype Raiders (agent bridge TCP)"; Proto = "TCP"; Ports = "24700-24720" }
)

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
	Write-Host "Elevating (UAC prompt)..." -ForegroundColor Yellow
	Start-Process pwsh -Verb RunAs -ArgumentList "-NoProfile", "-File", "`"$PSCommandPath`""
	exit 0
}

foreach ($r in $rules) {
	if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) {
		Write-Host "exists: $($r.Name)"
		continue
	}
	New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Protocol $r.Proto `
		-LocalPort $r.Ports -Action Allow -Profile Private, Domain | Out-Null
	Write-Host "added:  $($r.Name)" -ForegroundColor Green
}
Write-Host "Done - no more per-build firewall prompts." -ForegroundColor Green
Start-Sleep -Seconds 3
