warning - these scripts can generate a lot of metrics
an almost empty 3140 running 8.2 generates 5500.
our system with the highest volume count (170+) generates 130000 metrics on one node.


these run against 7-mode only.
I've tested against ontap 8.1.x and 8.2 using dataontap toolkit version 2.3, 2.4, and 3.0.


requirements:
graphite
dataontap toolkit: https://communities.netapp.com/community/products_and_solutions/microsoft/powershell
we run all of these scripts under an Active Directory account which has the appropriate permissions on the NetApp (i believe get-naperfdata requires admin level rights).
if you want to connect using -credential, then you will need to modify the scripts accordingly
you have to set at least the graphiteserver variable in each script

Get-NaPerfAll.ps1:
this script collects metrics using get-naperfdata. it can collect all of them if you empty the objectfilter variable.
schedule to run at startup and it will loop on its own

Get-NaVolStats.ps1
this script collects volume and aggregate used space and sends it to Graphite.
it runs from a list of NetApp controllers in .\filerlist.txt
schedule to run at whatever interval you want to capture the metrics

Get-NaSnapStats.ps1
this script collects volume snapshot used space and sends it to Graphite
it runs from a list of NetApp controllers in .\filerlist.txt
schedule to run at whatever interval you want to capture the metrics
