﻿
#*************************************************************************
# Script Name - 
# Author	  -  Daniele Grandini - QND
# Version	  - 1.0 30-04-2016
# Purpose     - 
#               
# Assumptions - 
#				
#               
# Parameters  - TraceLevel
#             - ComputerName
#				- SourceId
#				- ManagedEntityId
# Command Line - .\test.ps1 4 "serverName" '{1860E0EB-8C21-41DA-9F35-2FE9343CCF36}' '{1860E0EB-8C21-41DA-9F35-2FE9343CCF36}'
# If discovery must be added the followinf parameters
#				SourceId ($ MPElement $ )
#				ManagedEntityId ($ Target/Id $)
#
# Output properties
#
# Status
#    
#
#*************************************************************************


# Get the named parameters
param([int]$traceLevel=2,

[Parameter (Mandatory=$true)][string]$clientId,
[Parameter (Mandatory=$true)][string]$SubscriptionId,
[string]$Proxy,
[Parameter (Mandatory=$true)][string]$AuthBaseAddress,
[Parameter (Mandatory=$true)][string]$ResourceBaseAddress,
[Parameter (Mandatory=$true)][string]$ADUserName,
[Parameter (Mandatory=$true)][string]$ADPassword,
[Parameter (Mandatory=$true)][string]$resourceURI,
[string]$OMSAPIVersion='2015-03-20',
[int] $MaxAgeHours=2,
[int] $LookBackHours=24*7,
[int] $allInstances=0, #issues managing boolean values from OpsMgr
[string] $excludePattern,
[string] $dataTypes=''
)
 
	[Threading.Thread]::CurrentThread.CurrentCulture = "en-US"        
    [Threading.Thread]::CurrentThread.CurrentUICulture = "en-US"

#region Constants	
#Constants used for event logging
$SCRIPT_NAME			= "QND.OMS.GetLastSystemsData"
$SCRIPT_VERSION = "1.0"

#Trace Level Costants
$TRACE_NONE 	= 0
$TRACE_ERROR 	= 1
$TRACE_WARNING = 2
$TRACE_INFO 	= 3
$TRACE_VERBOSE = 4
$TRACE_DEBUG = 5

#Event Type Constants
$EVENT_TYPE_SUCCESS      = 0
$EVENT_TYPE_ERROR        = 1
$EVENT_TYPE_WARNING      = 2
$EVENT_TYPE_INFORMATION  = 4
$EVENT_TYPE_AUDITSUCCESS = 8
$EVENT_TYPE_AUDITFAILURE = 16

#Standard Event IDs
$FAILURE_EVENT_ID = 4000		#errore generico nello script
$SUCCESS_EVENT_ID = 1101
$START_EVENT_ID = 1102
$STOP_EVENT_ID = 1103

#TypedPropertyBag
$AlertDataType = 0
$EventDataType	= 2
$PerformanceDataType = 2
$StateDataType       = 3

$EventSource = 'Progel Script'
$EventLog= 'Operations Manager'
#endregion

#region Logging

if ([System.Diagnostics.EventLog]::SourceExists($EventSource) -eq $false) {
    [System.Diagnostics.EventLog]::CreateEventSource($EventSource, $eventlog)
}

function Log-Params
{
    param($Invocation)
    $line=''
    foreach($key in $Invocation.BoundParameters.Keys) {$line += "$key=$($Invocation.BoundParameters[$key])  "}
	Log-Event $START_EVENT_ID $EVENT_TYPE_INFORMATION  ("Starting script. Invocation Name:$($Invocation.InvocationName)`n Parameters`n $line") $TRACE_INFO
}

function Create-Event
  {
    param(
    [int] $eventID, 
    [int] $eventType,
    [string] $msg,
    [string[]] $parameters)

    switch ($eventType) {
        $EVENT_TYPE_SUCCESS {$nativeType=[System.Diagnostics.EventLogEntryType]::Information}
        $EVENT_TYPE_ERROR {$nativeType=[System.Diagnostics.EventLogEntryType]::Error}
        $EVENT_TYPE_WARNING {$nativeType=[System.Diagnostics.EventLogEntryType]::Warning}
        $EVENT_TYPE_INFORMATION {$nativeType=[System.Diagnostics.EventLogEntryType]::Information}
        $EVENT_TYPE_AUDITSUCCESS {$nativeType=[System.Diagnostics.EventLogEntryType]::AuditSuccess}
        $EVENT_TYPE_AUDITFAILURE {$nativeType=[System.Diagnostics.EventLogEntryType]::AuditFailure}
        default {
            Write-Verbose 'match?'
            $nativeType=[System.Diagnostics.EventLogEntryType]::Information
        }
    }
    $event = New-Object System.Diagnostics.EventInstance($eventID,1,$nativeType)

    $evtObject = New-Object System.Diagnostics.EventLog;
    $evtObject.Log = $EventLog;
    $evtObject.Source = $EventSource;
    $parameters = @($msg) + $parameters
    $evtObject.WriteEvent($event, $parameters)
  }


function Log-Event
{
	param($eventID, $eventType, $msg, $level)
	
	Write-Verbose ("Logging event. " + $SCRIPT_NAME + " EventID: " + $eventID + " eventType: " + $eventType + " Version:" + $SCRIPT_VERSION + " --> " + $msg)
	if($level -le $P_TraceLevel)
	{
		Write-Host ("Logging event. " + $SCRIPT_NAME + " EventID: " + $eventID + " eventType: " + $eventType + " Version:" + $SCRIPT_VERSION + " --> " + $msg)
        Create-Event -eventID $eventID -eventType $eventType -msg ($msg + "`n" + "Version :" + $SCRIPT_VERSION) -parameters @($SCRIPT_NAME,$SCRIPT_VERSION)
		#$g_API.LogScriptEvent($SCRIPT_NAME,$eventID,$eventType, ($msg + "`n" + "Version :" + $SCRIPT_VERSION))
	}
}
#endregion

#region Discovery Helpers
Function Throw-EmptyDiscovery
{
	param($SourceId, $ManagedEntityId)

	$oDiscoveryData = $g_API.CreateDiscoveryData(0, $SourceId, $ManagedEntityId)
	Log-Event $FAILURE_EVENT_ID $EVENT_TYPE_WARNING "Exiting with empty discovery data" $TRACE_INFO
	$oDiscoveryData
	If($traceLevel -eq $TRACE_DEBUG)
	{
		#just for debug proposes when launched from command line does nothing when run inside OpsMgr Agent
		$g_API.Return($oDiscoveryData)
	}
}

Function Throw-KeepDiscoveryInfo
{
param($SourceId, $ManagedEntityId)
	$oDiscoveryData = $g_API.CreateDiscoveryData(0,$SourceId,$ManagedEntityId)
	#Instead of Snapshot discovery, submit Incremental discovery data
	$oDiscoveryData.IsSnapshot = $false
	Log-Event $FAILURE_EVENT_ID $EVENT_TYPE_WARNING "Exiting with null non snapshot discovery data" $TRACE_INFO
	$oDiscoveryData    
	If($traceLevel -eq $TRACE_DEBUG)
	{
		#just for debug proposes when launched from command line does nothing when run inside OpsMgr Agent	
		$g_API.Return($oDiscoveryData)
	}
}

#endregion


Function Return-Bag
{
    param($object, $key)
    try {    
		$bag = $g_api.CreatePropertyBag()
        foreach($property in $object.Keys) {
		    $bag.AddValue($property, $object[$property])
        }
        $bag

		if($traceLevel -eq $TRACE_DEBUG) {
			$g_API.AddItem($bag)
			$object.Keys | %{write-verbose ('{0}={1}' -f $_,$object[$_]) -Verbose}
		}
		

		Log-Event -eventID $SUCCESS_EVENT_ID -eventType $EVENT_TYPE_INFORMATION `
			-msg ('{0} - returned status bag ' `
				-f $object[$key]) `
			-level $TRACE_VERBOSE 
    }
    catch {
		Log-Event -eventID $FAILURE_EVENT_ID -eventType $EVENT_TYPE_WARNING `
			-msg ('{0} - error creating status bag {1}' `
				-f $object[$key]), $_.Message `
			-level $TRACE_VERBOSE 
    }
}


Function Import-ResourceModule
{
	param($moduleName, $ArgumentList=$null)
	if (Get-Module -Name $moduleName) {return}

	$moduleName = '{0}.psm1' -f $moduleName
	$ResPath = (get-itemproperty -path 'HKLM:\system\currentcontrolset\services\healthservice\Parameters' -Name 'State Directory').'State Directory' + '\Resources'
	if(Test-Path $ResPath) {
		$module = @(get-childitem -path $ResPath -Filter $moduleName -Recurse)[0]
	}
	if($module) { $module = $module.FullName}
	else {$module = "$PSScriptRoot\$moduleName"}

	If (Test-Path $module) {Import-Module -Name $module -ArgumentList $ArgumentList}
	else {Throw [System.DllNotFoundException] ('{0} not found' -f $module)}
}


#Start by setting up API object.
	$P_TraceLevel = $TRACE_VERBOSE
	$g_Api = New-Object -comObject 'MOM.ScriptAPI'
	#$g_RegistryStatePath = "HKLM\" + $g_API.GetScriptStateKeyPath($SCRIPT_NAME)

	$dtStart = Get-Date
	$P_TraceLevel = $traceLevel
	Log-Params $MyInvocation

	try {
		Import-ResourceModule -moduleName QNDAdal -ArgumentList @($false)
		Import-ResourceModule -moduleName QNDAzure
	}
	catch {
		Log-Event $FAILURE_EVENT_ID $EVENT_TYPE_ERROR ("Cannot load required powershell modules $Error") $TRACE_ERROR
		exit 1	
	}

try
{
	if($proxy) {
		Log-Event $FAILURE_EVENT_ID $EVENT_TYPE_WARNING ("Proxy is not currently supported {0}" -f $proxy) $TRACE_WARNING
	}
	$pwd = ConvertTo-SecureString $ADPassword -AsPlainText -Force
	$cred = New-Object System.Management.Automation.PSCredential ($ADUserName, $pwd)
	$connection = Get-AdalAuthentication -resourceURI $resourcebaseAddress -authority $authBaseAddress -clientId $clientId -credential $cred
}
catch {
	Log-Event $FAILURE_EVENT_ID $EVENT_TYPE_ERROR ("Cannot get Azure AD connection aborting $Error") $TRACE_ERROR
	exit 1	
}

try {

	$query = 'Type NOT IN {"Heartbeat","Usage","QNDHeartbeatEx_CL"} | measure max(TimeGenerated) as LastData by Computer, Type'

	$startDate=(Get-Date).AddHours(-$LookBackHours)
	$endDate=Get-Date
	$systems=Get-QNDOMSQueryResult -query $query -startDate $startDate -endDate $endDate -authToken ($connection.CreateAuthorizationHeader()) -ResourceBaseAddress  $ResourceBaseAddress -resourceURI $resourceURI -OMSAPIVersion $OMSAPIVersion -timeout $timeout



	#in this version just remove no fwdn systems
	$nofqdnSys=@()
	$systems| %{If(! $_.Computer.contains('.')){$nofqdnSys+=$_}}

	foreach($nofqdn in $nofqdnSys) {
		foreach($sys in $systems) {
			if($sys.Computer -imatch "$($nofqdn.Computer).") {
				$systems[$systems.IndexOf($nofqdn)]=$null
			}
		}
	}

	#exluded systems
	If(! [String]::IsNullOrEmpty($excludePattern)) {
		foreach($sys in $systems) {
			if($sys.Computer -imatch $excludePattern) {
				$systems[$systems.IndexOf($sys)]=$null
			}
		}
	
	}

	#in the end let's just keep not null elements
	$cleanSys = @()
	$systems | %{if($_) {$cleanSys+=$_}}
	
	write-verbose ('Returned systems {0} clean systems {1}' -f $systems.count, $cleanSys.Count)
	
	$systems=$null


	if(![String]::IsNullOrEmpty($dataTypes)) {
		foreach($sys in $cleanSys) {
			if($sys.Type -inotmatch $dataTypes) {
				$cleanSys[$cleanSys.IndexOf($sys)]=$null
			}
		}
		$cleanSys = $cleanSys | where {$_ -ne $null}
		#in this acase I need to check for oldest datapoint, if *ANY* of the Data types has obsolete data I want to be alerted
		$totalInstances = $cleanSys | group Computer | select @{n='Computer';e={$_.Name}},@{n='Type';e={'_Total'}},@{n='LastData';e={ ($_.group | measure LastData -min).minimum}}
	}
	else {$totalInstances = $cleanSys | group Computer | select @{n='Computer';e={$_.Name}},@{n='Type';e={'_Total'}},@{n='LastData';e={ ($_.group | measure LastData -max).maximum}}}

	#if we're looking for specific Types add the _total instance to the types so that in the context we can report everything, if not just report the _total instance as before
	if([String]::IsNullOrEmpty($dataTypes)) {$cleanSys = $totalInstances} else {$cleanSys += $totalInstances}

	if ($allInstances -ne 0) {
		foreach($sys in $cleanSys) {
			if(! [String]::IsNullOrEmpty($sys.Computer) ) {	
				$diff = [DateTime]::Now - [DateTime]($sys.lastdata)
				$hash=@{
				'QNDType' ="Data"
				'Computer'= $sys.Computer.ToLower()
				'Type'=$sys.Type
				'LastData'= $sys.lastdata
				'AgeHours'= $diff.TotalHours
				}			
				Return-Bag -object $hash -key Computer

			}
		}
	}
	else {
		$obsolete = @()
		$cleanSys | %{if(([DateTime]::Now - [DateTime]($_.lastdata)).TotalHours -ge $MaxAgeHours) {$obsolete+=$_}}
		write-verbose ('Obsolete systems {0}' -f $obsolete.count)
		if($obsolete.count -gt 0) {$sampleSys = [System.String]::Join(',',($obsolete | select -first 10))}
		else {$sampleSys=''}

		$hash=@{
			'QNDType' ="Summary"
			'ObsoleteDataSystems'= $obsolete.count
			'AgeHours'= $maxAgeHours
			'First10'= $sampleSys
		}			
		Return-Bag -object $hash -key QNDType
	}



	If ($traceLevel -eq $TRACE_DEBUG)
	{
		#just for debug proposes when launched from command line does nothing when run inside OpsMgr Agent	
		#it breaks in exception when run insde OpsMgr and POSH IDE	
		$g_API.ReturnItems() 
	}

	
	Log-Event $STOP_EVENT_ID $EVENT_TYPE_SUCCESS ("has completed successfully in " + ((Get-Date)- ($dtstart)).TotalSeconds + " seconds.") $TRACE_INFO
}
Catch [Exception] {
	Log-Event $FAILURE_EVENT_ID $EVENT_TYPE_WARNING ("Main " + $Error) $TRACE_WARNING	
	write-Verbose $("TRAPPED: " + $_.Exception.GetType().FullName); 
	Write-Verbose $("TRAPPED: " + $_.Exception.Message); 
}



