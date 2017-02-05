A Powershell version of '[RunAs](https://technet.microsoft.com/en-us/library/cc771525(v=ws.11).aspx)' that accepts a PSCredential instead of always prompting for a password.

This can be used to launch apps with credentials stashed in your profile. You can stash credentials in your profile like so:

```powershell
# run this to get the encrypted pw..
ConvertFrom-SecureString (Get-Credential 'domain\username').Password

# put this in your profile (replacing xxxx with the encrypted pw)..
$mycreds = New-Object Management.Automation.PSCredential('domain\username', (ConvertTo-SecureString 'xxxx'))

# handy function to do it for you..
function stashcreds ($var) {
    $cred = Get-Credential
    [IO.File]::AppendAllText($profile, "`n`$$var = New-Object Management.Automation.PSCredential('$($cred.Username)', (ConvertTo-SecureString '$(ConvertFrom-SecureString $cred.Password)'))`n")
}
```

..you can use it in a desktop shortcut, e.g.:
`powershell.exe -command runas -netonly $mycreds ssms`


See also [Working with Passwords, Secure Strings and Credentials in Windows PowerShell](https://social.technet.microsoft.com/wiki/contents/articles/4546.working-with-passwords-secure-strings-and-credentials-in-windows-powershell.aspx).



# installation #
from [PowerShell Gallery](https://www.powershellgallery.com/packages/RunAs) (requires Powershell V5 or Win10)..
```powershell
Install-Module RunAs
```
manually..
```powershell
ni "$(($env:PSModulePath -split ';')[0])\RunAs\RunAs.psm1" -f -type file -value (irm "https://raw.githubusercontent.com/gfody/PowershellModules/master/RunAs/RunAs.psm1")
```
**note**: you must manually import this module since `runas.exe` is in the system path it will take precedent over Powershell's auto import.
```powershell
Import-Module RunAs
```
