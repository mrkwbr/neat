$filerlist = ".\filerlist.txt"
$graphiteserverport = 2003
$graphiteserver = "0.0.0.0"

if (-Not (Get-Module DataONTAP)){
  Import-Module DataONTAP -EA 'STOP' -Verbose:$false
}
$filers = gc $filerlist
$items = @{}

foreach ($filer in $filers){
   Try{
      Connect-NaController $filer

      $timestamp = get-date((get-date).ToUniversalTime()) -uformat "%s"
      get-navol | ForEach {
      $value = "storage.NetApp." + $filer + "." + $_.Name + ".sizeused" + " " + $_.sizeused  + " " + $timestamp
      $items.Add($items.Count, $value)
      }

      $timestamp = get-date((get-date).ToUniversalTime()) -uformat "%s"
      get-naaggr | ForEach {
      $value = "storage.NetApp." + $filer + ".aggregate." + $_.Name + ".sizeused" + " " + $_.sizeused  + " " + $timestamp
      If(!$items.ContainsKey($value)){
            $items.Add($items.Count, $value)
      }
      }

   }
   Catch{
      Write-Host "Error connecting to filer " $filer
   }
}

$socket = New-Object System.Net.Sockets.TCPClient
$socket.connect($graphiteserver, $graphiteserverport)
$stream = $socket.GetStream()
$writer = new-object System.IO.StreamWriter($stream)

foreach($i in 0..($items.count-1)){
   $writer.WriteLine($items[$i])
}

$writer.Flush() 
$writer.Close() 
$stream.Close() 
$socket.close()
