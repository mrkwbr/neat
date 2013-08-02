<#
.SYNOPSIS
    get metrics from a NetApp controller and send to Graphite
.DESCRIPTION
    this script can retrieve and process all metrics from a 7-mode NetApp controller.
    depending on the controller setup (# of volumes, protocols enabled, replication relationships, etc) this can be a very large # of metrics - easily over 100K 
    - so will will probably need to filter out whole categories that are unwanted.
.PARAMETER controller
    target NetApp controller
.PARAMETER interval
    interval in seconds to wait between executing runs. default is 45.
.EXAMPLE
    .\Get-NaPerfAll.ps1 -controller toaster1 -interval 60
   
    get metrics from NetApp controller toaster1 waiting 60 seconds inbetween each execution and send to Graphite
.NOTE
    Uses the DataOnTap Toolkit: https://communities.netapp.com/community/products_and_solutions/microsoft/powershell
    This script borrows heavily from the concepts in Get-NaSysStat.ps1: https://communities.netapp.com/docs/DOC-10354
#>

param([string]$controller = "toaster1", [int]$interval = 45)

#begin variables
$graphiteserverport = 2003
$graphiteserver = "127.0.0.1"
$filer = connect-nacontroller $controller
#set to desired initial graphite prefix:
$globalprefix = "storage.NetApp." + $($controller.split('.')[0])
$sampletime = 0
$processtime = 0
#replace dirtychar with cleanchar:
$cleanchar = "_"
$dirtychar = '::',':', '?', '/', '\', '|', '*', '(', ')', '#', ' '
#strings to remove from results:
$removechar = ':00000000:00000000:00000000:00000000:00000000:00000000:00000000:00000000','/vol/'
#perf objects to not retrieve - see get-naperfobject for complete list
$objectfilter = @("audit_ng",
                "dump",
                "flexcache",
                "fpolicy_stats_policy",
                "fpolicy_stats_server",
                "hya_block_count",
                "hya_ttencoding",
                "iscsi_conn",
                "iscsi_lif",
                "lun",
                "ndmp",
                "nrv",
                "priorityqueue",
                "prisched",
                "repl_exovol_scanner",
                "repl_exovol_writer",
                "repl_rcvr_mgr",
                "repl_rcvr_node",
                "repl_snapdiff",
                "repl_sndr_mgr",
                "repl_sndr_node",
                "rsm_dst_relation",
                "rsm_src_relation",
                "sparse",
                "striped",
                "stripedattributes",
                "stripedfileop",
                "stripedfileoperrors",
                "stripedlock",
                "stripedmemory",
                "stripedopclient",
                "stripedopclienterrors",
                "stripedopserver",
                "stripedopservererrors",
                "target",
                "vnvram",
                "wafl_hya_per_aggr",
                "wafl_hya_per_vvol")
#individual counters to filter out of retrieved metrics:
$counterfilter = @("perf.perf.cpu_disk_util_matrix",
                "perf.perf.domain_switches")
#end variables

if (-Not (Get-Module DataONTAP)){
  Import-Module DataONTAP -EA 'STOP' -Verbose:$false
}

function hashit ($inobject){
  $returnhash = @{}
  foreach ($sample in $inobject){
  $timestamp = $sample.timestamp
    $prefix = "$($sample.object).$($sample.name)"
    foreach($sam in $sample.counters){
      $value = @($sam.value,$timestamp)
      $returnhash.add("$prefix.$($sam.name)",$value)
    }
  }
  return $returnhash
}

function buildperfdef{
  $objects = get-naperfobject
  $allcounters = foreach($obj in $objects){
    $counters = Get-NaPerfCounter -name $obj -ea SilentlyContinue 
    foreach($counter in $counters){
      [PSCustomObject]@{
        "name" = $counter.name
        "base" = $counter.basecounter
        "prop" = $counter.properties
        "type" = $counter.type
        "unit" = $counter.unit
        "labels" = $counter.labels
        "object" = $obj
      }
    }
  }
  $counterlt = @{}
  foreach($c in $allcounters){
    $value = $c.name +  "." + $c.object
    $counterlt.add($value, $c)
  }
  return $counterlt
}

function getcounterdata{
  $objects = get-naperfobject | where({$objectfilter -notcontains $_.name})
  $returnvalue = foreach($obj in $objects){
    $data = get-naperfdata -name $obj -ea SilentlyContinue 
    foreach($datum in $data){
      [PSCustomObject]@{
        "object" = $obj
        "counters" = $datum.counters
        "name" = $datum.name
        "timestamp" = $datum.timestamp
        "timestampdt" = $datum.timestampdt
      }
    }
  }
  return $returnvalue
}

function counterraw ($v1)
{
  $returnvalue = $v1
  return $returnvalue
}

function counterdelta ($v2, $v1)
{
  $returnvalue = $v2 - $v1
  return $returnvalue
}

function counterrate ($v2, $v1, $timeint)
{
  $returnvalue = ($v2 - $v1)/$timeint
  return $returnvalue
}

function counteraverage ($v2, $v1, $t2, $t1)
{
  if ((($v2 - $v1) -eq 0) -or (($t2 - $t1) -eq 0)) 
  {
    $returnvalue = 0
  }
  else
  {
    $returnvalue = (($v2 - $v1)/($t2 - $t1))
  }
  return $returnvalue
}

function sendtographite ($metrics)
{
  $socket = new-object system.net.sockets.tcpclient
  $socket.connect($graphiteserver, $graphiteserverport)
  $stream = $socket.getstream()
  $writer = new-object system.io.streamwriter($stream)

  foreach($i in 0..($metrics.count-1)){
    $writer.writeline($metrics[$i])
  }

  $writer.flush() 
  $writer.close() 
  $stream.close()
  $socket.close() 
}


$reppattern = [string]::join('|', ($dirtychar | % {[regex]::escape($_)}))
$delpattern = [string]::join('|', ($removechar | % {[regex]::escape($_)}))

#initialize counter definitions
$counterlt = buildperfdef

#get first counter sample
$currentsample = getcounterdata

$nextsample = $true
do
{
  $results = @{}
  $adjustedinterval = $interval - $processtime
  Start-Sleep $adjustedinterval
  $previoussample = $currentsample
  $currentsample = getcounterdata
  $previoushash = hashit $previoussample
  $currenthash = hashit $currentsample

  foreach ($counterset in $currentsample){
    $counterset_counters = $counterset.counters
    foreach ($counter in $counterset_counters){
    $cname = $counter.name
    $oname = $counterset.object.name
    $ctype = $counterlt.item("$cname.$oname")
    $cbase = $ctype.base
    $key = "$($counterset.object).$($counterset.name).$cname"
    $cleankey =  ($key -replace $delpattern) -replace $reppattern,$cleanchar
    if($($ctype.base) -ne $null){
      $basekey = "$($counterset.object).$($counterset.name).$($ctype.base)"
    }
	  switch ($ctype.prop){
	    "raw"
		{
          if ($ctype.type){
            $count = $counter.value.split(",").count
            for($i=1; $i -le $count; $i++){
              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
              $acounter = $counter.value.split(",")[$i-1]
              $result = $globalprefix + "." + $akey + " " + (counterraw $acounter) + " " + $($counterset.timestamp)
              $results.add($results.count, $result)
            }
          }
		  else{
          $result = $globalprefix + "." + $cleankey + " " + (counterraw $counter.value) + " " + $($counterset.timestamp)
          $results.add($results.count, $result)
          }
          continue
		}
	    "delta"
		{
          if ($ctype.type){
            if ({$counterfilter -contains $key}){continue}
            $count = $counter.value.split(",").count
            for($i=1; $i -le $count; $i++){
              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
              $acounter = $counter.value.split(",")[$i-1]
              $pcounter = $previoushash.item($key)[0].split(",")[$i-1]
              $result = $globalprefix + "." + $akey + " " + (counterdelta $acounter $pcounter) + " " + $($counterset.timestamp)
              $results.add($results.count, $result)
           }
          }
		  else{
          $result = $globalprefix + "." + $cleankey + " " + (counterdelta $counter.value $previoushash.item($key)[0]) + " " + $($counterset.timestamp)
          $results.add($results.count, $result)
          }
          continue
		}
        "rate" 
		{
          $timediff = $counterset.timestamp - $previoushash.item($key)[1]
          if ($ctype.type){
            if ({$counterfilter -contains $key}){continue}
            $count = $counter.value.split(",").count
            for($i=1; $i -le $count; $i++){
              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
              $acounter = $counter.value.split(",")[$i-1]
              $pcounter = $previoushash.item($key)[0].split(",")[$i-1]
              $result = $globalprefix + "." + $akey + " " + (counterdelta $acounter $pcounter $timediff) + " " + $($counterset.timestamp)
              $results.add($results.count, $result)
           }
          }
		  else{
          $result = $globalprefix + "." + $cleankey + " " + (counterdelta $counter.value $previoushash.item($key)[0] $timediff) + " " + $($counterset.timestamp)
          $results.add($results.count, $result)
          }
          continue
		}
        "average" 
		{
          $currentbase = $currenthash.item($basekey)[0]
          $prevbase = $previoushash.item($basekey)[0]
          if ($ctype.type){
            $count = $counter.value.split(",").count
            for($i=1; $i -le $count; $i++){
              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
              $acounter = $counter.value.split(",")[$i-1]
              $pcounter = $previoushash.item($key)[0].split(",")[$i-1]
              $abase = $currentbase.split(",")[$i-1]
              $pbase = $prevbase.split(",")[$i-1]
              $result = $globalprefix + "." + $akey + " " + (counteraverage $acounter $pcounter $abase $pbase) + " " + $($counterset.timestamp)
              $results.add($results.count, $result)
            }
          }
		  else{
            $result = $globalprefix + "." + $cleankey + " " + (counteraverage $counter.value $previoushash.item($key)[0] $currentbase $prevbase) + " " + $($counterset.timestamp)
            $results.add($results.count, $result)
          }
          continue
		}
        "percent"  
		{
          $currentbase = $currenthash.item($basekey)[0]
          $prevbase = $previoushash.item($basekey)[0]
          if ($ctype.type){
            $count = $counter.value.split(",").count
            for($i=1; $i -le $count; $i++){
              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
              $acounter = $counter.value.split(",")[$i-1]
              $pcounter = $previoushash.item($key)[0].split(",")[$i-1]
              $abase = $currentbase.split(",")[$i-1]
              $pbase = $prevbase.split(",")[$i-1]
              $result = $globalprefix + "." + $akey + " " + (100 * (counteraverage $acounter $pcounter $abase $pbase)) + " " + $($counterset.timestamp)
              $results.add($results.count, $result)
            }
          }
		  else{
            $result = $globalprefix + "." + $cleankey + " " + (100 * (counteraverage $counter.value $previoushash.item($key)[0] $currentbase $prevbase)) + " " + $($counterset.timestamp)
            $results.add($results.count, $result)
          }
          continue
		}
  	    "delta,no-zero-values"
		{
          if ($ctype.type){
# this is really slow so commented out for now
#            $count = $counter.value.split(",").count
#            for($i=1; $i -le $count; $i++){
#              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
#              $acounter = $counter.value.split(",")[$i-1]
#              $pcounter = $previoushash.item($key)[0].split(",")[$i-1]
#              $result = $globalprefix + "." + $akey + " " + (counterdelta $acounter $pcounter) + " " + $($counterset.timestamp)
#              $results.add($results.count, $result)
#            }
          }
		  else{
          $result = $globalprefix + "." + $cleankey + " " + (counterdelta $counter.value $previoushash.item($key)[0]) + " " + $($counterset.timestamp)
          $results.add($results.count, $result)
          }
          continue
		}
  	    "average,no-zero-values"
		{
          $currentbase = $currenthash.item($basekey)[0]
          $prevbase = $previoushash.item($basekey)[0]
          if ($ctype.type){
            $count = $counter.value.split(",").count
            for($i=1; $i -le $count; $i++){
              $akey = "$cleankey.$($ctype.labels.split(",")[$i-1].tolower())" -replace $reppattern,$cleanchar
              $acounter = $counter.value.split(",")[$i-1]
              $pcounter = $previoushash.item($key)[0].split(",")[$i-1]
              $abase = $currentbase.split(",")[$i-1]
              $pbase = $prevbase.split(",")[$i-1]
              $result = $globalprefix + "." + $akey + " " + (counteraverage $acounter $pcounter $abase $pbase) + " " + $($counterset.timestamp)
              $results.add($results.count, $result)
            }
          }
		  else{
            $result = $globalprefix + "." + $cleankey + " " + (counteraverage $counter.value $previoushash.item($key)[0] $currentbase $prevbase) + " " + $($counterset.timestamp)
            $results.add($results.count, $result)
          }
          continue
		}
        "string"{continue}
  	    "delta,no-display"{continue}
        "raw,no-display"{continue}
        default{
        }
      }
	  }
	}

# send to graphite

   sendtographite $results

}
While ($NextSample)
