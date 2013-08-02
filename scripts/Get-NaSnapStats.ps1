$filerlist = ".\filerlist.txt"
$graphiteserverport = 2003
$graphiteserver = "0.0.0.0"

if (-Not (Get-Module DataONTAP)){
  Import-Module DataONTAP -EA 'STOP' -Verbose:$false
}
$filers = gc $filerlist

foreach ($filer in $filers){
   Try{
      Connect-NaController $filer
      $items = @{}

      $timestamp = get-date((get-date).ToUniversalTime()) -uformat "%s"
      get-naefficiency | ForEach {
      $value2 = "storage.NetApp." + $filer + "." + $_.Name + ".snapsizeused" + " " + $_.snapusage.used  + " " + $timestamp
      $items.Add($items.Count, $value2)
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
   }
   Catch{
      Write-Host "Error connecting to filer " $filer
   }
}
