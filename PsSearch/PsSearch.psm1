Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class TextDetector
{
	public static bool CheckFile(FileInfo f)
	{
		var bytes = new byte[512]; int len;
		try { using (var s = new FileStream(f.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
			len = s.Read(bytes, 0, bytes.Length); }
		catch { return false; }

		if ((len > 2 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
		 || (len > 1 && bytes[0] == 0xFF && bytes[1] == 0xFE)
		 || (len > 1 && bytes[0] == 0xFE && bytes[1] == 0xFF)
		 || (len > 3 && bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF))
			return true;

		for (int i = 0; i < len; i++)
			if (bytes[i] < 9 || bytes[i] == 11 || bytes[i] == 12 || (bytes[i] > 13 && bytes[i] < 32))
				return false;

		return true;
	}
}
'@

# validate a CONTAINS search string, capture terms..
$textQueryExp = New-Object Text.RegularExpressions.Regex(
    '^\s*(?:(?:\s*\(+\s*)*(?:(?:\"([^"]+)\")|(\*?\w+\*?))(?:\s*\)+\s*)*(?:(?:\s+(?:near|and not|and|or)\s+)|(?:\s*(?:(?:\&\s*\!)|\&|\||\~)\s*))?)+$',
    @([Text.RegularExpressions.RegexOptions]::IgnoreCase, [Text.RegularExpressions.RegexOptions]::Compiled))

# return only captures, e.g.: '^(?:(\w+) ?)+$' and 'one two three' returns @('one','two','three')
function Split-StringRegex ([regex]$r, [string]$s) {
    $m = $r.Matches($s)
    @(for ($g = 1; $g -lt $m.Groups.Count; $g++) {
        foreach ($c in $m.Groups[$g].Captures) { $c.Value } })
}

# validate and convert a search string, e.g.: '((ducks near "angry*") or ("angry ducks" near lake)) and not (duckling|squirrel|fox)'
# ..to 'ducks|angry\w*|angry ducks|lake|duckling|squirrel|fox' to be used as regex for highlighting..
function ParseTextQuery ([string]$s) {
    $words = (Split-StringRegex $textQueryExp $s.Trim())
    if ($words) { return $words.replace('*', '\w*') -join '|' } else {
        Write-Host "'$s' is not a valid text criteria. Multiple terms should be used with keywords such as AND or NEAR." -Foreground red
        Write-Host "To search for a phrase, wrap the phrase in quotes. Add the -query switch to use a raw predicate." -Foreground red
        Write-Host "For help constructing a valid search see: https://msdn.microsoft.com/en-us/library/ms691971(v=vs.85).aspx" -Foreground red
    }
}

function Write-Highlight ([string]$s, [regex]$r) {
    $o = 0
    foreach($m in $r.Matches($s)) {
        Write-Host $s.Substring($o, $m.Index - $o) -NoNewline
        Write-Host $s.Substring($m.Index, $m.Length) -NoNewline -Foreground black -Background yellow
        $o = $m.Index + $m.Length
    }
    Write-Host $s.Substring($o)
}

function Get-IndexedPaths ([string]$path = $pwd) {
    if (![IO.Path]::IsPathRooted($path)) { $path = Resolve-Path $path }
    $drive = [IO.Path]::GetPathRoot($path)

    $root = ((Get-ItemProperty 'Registry::HKLM\Software\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\SearchRoots\*' `
        | Where-Object URL -like "file:///$drive*").url) + $path.Substring($drive.Length)

    Get-ItemProperty 'Registry::HKLM\Software\Microsoft\Windows Search\CrawlScopeManager\Windows\SystemIndex\WorkingSetRules\*' `
        | Where-Object URL -like "$($root.Replace('\','`\').Replace(']','`]').Replace('[','`['))*" `
        | Where-Object Include | % { $path + $_.URL.Substring($root.Length) }
<#
.Synopsis
    Lists all locations in the Windows Search index at or below the specified path.
.Parameter path
    Path to search, defaults to current directory.
#>
}

function Search-Index ($s, $filePattern, [string]$path = $pwd, [string]$directoryPattern, [int]$top, [switch]$noTraverse, [switch]$query, [switch]$count, [string]$groupBy) {
    if (!$s -and !$filePattern -and !$directoryPattern) { help Search-Index; return }
    if (!($s -is [string]) -and !$filePattern) { $filePattern = $s; $s = $null }
    if ($filePattern -and $filePattern.IndexOfAny('/:\') -ge 0) { # detect swapped path/filePattern..
        if ($path.Contains('*')) { $path, $filePattern = $filePattern, $path } else { $path = $filePattern; $filePattern = $null } }

    if ($s -and !$query -and !$s.StartsWith('"') -and !$s.EndsWith('"') -and !$s.Contains(' ')) { $s = '"' + $s + '"' }
    if ($s -and !$query -and !(ParseTextQuery($s))) { return }

    $scope = 'scope'; if ($noTraverse) { $scope = 'directory' }
    if ($s -and !$query) { $s = "contains('$s')" }
    $s = "select $(if($top) { "top $top " })system.itemPathDisplay from systemIndex where $scope='$path'$(if($s) { " and ($s)" })"
    if ($filePattern) { $s += " and ($(@($filePattern | % { "system.itemName like '$($_.Replace('*','%').Replace('?','_'))'" }) -join ' or '))" }
    if ($directoryPattern) { $s += " and system.itemPathDisplay like '$($directoryPattern.Replace('*','%').Replace('?','_'))'" }
    if ($groupBy) { $s = "group on system.$groupBy aggregate count() over ($s)" }

    $d = New-Object Data.DataSet
    $total = (New-Object Data.OleDb.OleDbDataAdapter $s, 'Provider=Search.CollatorDso').Fill($d)
    if ($count) { $total }
    elseif ($groupBy) { foreach ($row in $d.Tables[0]) { New-Object PsObject -Prop @{ $groupBy = $row.Item(0); 'Count' = $row.Count } } }
    else { foreach ($row in $d.Tables[0]) { [IO.FileInfo]$row.Item(0) } }

    if ($total -eq 0) { if ((Get-IndexedPaths -path:$path).Count -eq 0) {
        Write-Host "There is nothing indexed beneath '$path'. Check your index settings in Control Panel." -Foreground red
        Write-Host "You can use Get-IndexedPaths <path> to list indexed roots beneath a specific path." -Foreground red
    } }
<#
.Synopsis
    Queries the Windows Search index, returns FileInfo objects.
.Description
    For more about Windows Search, see: https://msdn.microsoft.com/en-us/library/windows/desktop/aa965362(v=vs.85).aspx
.Parameter s
    The full-text search argument for a CONTAINS predicate, e.g.: "donkey NEAR water"
.Parameter filePattern
    One or more patterns to match against the file name, e.g.: "*.txt" ".config"
.Parameter path
    Path to search, defaults to current directory.
.Parameter directoryPattern
    A pattern to match against the full path, e.g: "*Users/.config/*"
.Parameter top
    Limit results.
.Parameter noTraverse
    Limit search to specified directory instead of including all subdirectories.
.Parameter query
    Indicates that the first parameter is a valid SQL predicate instead of an argument for CONTAINS.
    Windows Search SQL Syntax reference: https://msdn.microsoft.com/en-us/library/windows/desktop/bb231256(v=vs.85).aspx
.Parameter count
    Return count instead of FileInfo objects. When used with -groupBy, returns count of groups.
.Parameter groupBy
    Specify a property to group by, returns counts for each group instead of FileInfo objects.
    e.g.: -groupBy 'FileExtension', for all available properties see: https://msdn.microsoft.com/en-us/library/windows/desktop/bb760699(v=vs.85).aspx
#>
}

function Search-Files ([string]$pat, [parameter(ValueFromPipeline)]$file, [string]$path = $pwd, [int[]]$context = 3, [switch]$caseSensitive, [switch]$noTraverse, [switch]$simple) {
    if (!$pat) { help Search-Files; return }
    $regOptions = @([Text.RegularExpressions.RegexOptions]::Compiled)
    if (!$caseSensitive) { $regOptions += [Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $reg = New-Object Text.RegularExpressions.Regex(@($pat, [Regex]::Escape($pat))[$simple.isPresent], $regOptions)

    if (!($file -is [IO.FileInfo])) {
        $detectText = $true
        $gcArgs = @{ Path = $path; Filter = $null; Include = $null; Recurse = !$noTraverse }
        if (!($file -is [string])) { $gcArgs.Filter = '*'; $gcArgs.Include = $file } else { $gcArgs.Filter = $file }
        $file = (Get-ChildItem @gcArgs -file -ea silent)
    } else { $file = $input }

    $trim = $path.Length + [int]!$path.EndsWith('\')

    foreach ($f in $file) {
        if ($detectText -and ![TextDetector]::CheckFile($f)) { continue }
        $lastLine = 0
        Select-String $pat $f -context:$context -case:$caseSensitive -simple:$simple -ea silent | % {
            if ($lastLine -eq 0) { Write-Host $f.fullName.Substring($trim) -Foreground green }
            $line = $_.LineNumber - $_.Context.PreContext.Count
            foreach ($ctx in $_.Context.PreContext) { if ($line -ge $lastLine) {
                Write-Host $line -Foreground yellow -NoNewline; Write-Highlight ": $ctx" $reg; $line++; $lastLine = $line } }
            if ($line -ge $lastLine) {
                Write-Host $line -Foreground cyan -NoNewline; Write-Highlight ": $($_.line)" $reg; $line++; $lastLine = $line }
            foreach ($ctx in $_.Context.postContext) { if ($line -ge $lastLine) {
                Write-Host $line -Foreground yellow -NoNewline; Write-Highlight ": $ctx" $reg; $line++; $lastLine = $line; } }
        }
        if ($lastLine -gt 0) { Write-Host }
    }
<#
.Synopsis
    Searches for patterns in files and displays the results.
.Description
    Use for highlighting patterns found in files returned by Search-Index, or anything that returns FileInfo objects (like dir).
.Parameter pat
    Regular expression to highlight.
.Parameter file
    Expects FileInfo objects from pipeline, or specify a search path e.g.: *.txt,*.cs
.Parameter path
    Path to search, defaults to current directory.
.Parameter context
    Lines to include before and after a match.
.Parameter caseSensitive
    Indicates the pattern is case-sensitive.
.Parameter recurse
    Indicates the provided search path should include subdirectories. Ignored when using pipeline.
#>
}

function Search-Text ($s, $filePattern, [string]$path = $pwd, [string]$directoryPattern, [int]$top, [int[]]$context = 3, [switch]$noTraverse, [switch]$query) {
    if (!$s) { help Search-Text; return }
    if (!$query -and !$s.StartsWith('"') -and !$s.EndsWith('"') -and !$s.Contains(' ')) { $s = '"' + $s + '"' }
    if (!$query -and !($pat = ParseTextQuery $s)) { return }
    $reg = New-Object Text.RegularExpressions.Regex($pat, @([Text.RegularExpressions.RegexOptions]::IgnoreCase, [Text.RegularExpressions.RegexOptions]::Compiled))
    Search-Index $s $filePattern -path:$path -dir:$directoryPattern -top:$top -noTraverse:$noTraverse -q:$query | Search-Files $reg -context:$context -path:$path -no:$noTraverse
<#
.Synopsis
    Queries the Windows Search index and displays the results. If nothing is indexed then files are scanned individually which may take a while.
.Description
    Pipes Search-Index to Search-Files and derives a regular expression from the text query to use for highlighting.
.Parameter s
    The full-text search argument for Search-Index.
.Parameter filePattern
    The file patterns for Search-Index.
.Parameter path
    Path to search, defaults to current directory.
.Parameter directoryPattern
    The directory pattern for Search-Index.
.Parameter top
    Top parameter for Search-Index (limits results).
.Parameter context
    Context parameter for Search-Files.
.Parameter noTraverse
    NoTraverse parameter for Search-Index.
.Parameter query
    Query parameter for Search-Index.
#>
}

New-Alias search Search-Index
New-Alias ack Search-Text
New-Alias index Get-IndexedPaths

Export-ModuleMember -function Search-Index, Search-Files, Search-Text, Get-IndexedPaths -alias search, ack, index
