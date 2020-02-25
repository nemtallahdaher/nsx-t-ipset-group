# Script used to create segments in NSX-T

# Load script to do IP calculations
. ~\Documents\Get-CalculatedIPAddress_1.3.ps1

##### Set up TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 

##### Handle Self Signed Certificates
if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type)
{
$certCallback = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
        public static void Ignore()
        {
            if(ServicePointManager.ServerCertificateValidationCallback ==null)
            {
                ServicePointManager.ServerCertificateValidationCallback += 
                    delegate
                    (
                        Object obj, 
                        X509Certificate certificate, 
                        X509Chain chain, 
                        SslPolicyErrors errors
                    )
                    {
                        return true;
                    };
            }
        }
    }
"@
    Add-Type $certCallback
 }
[ServerCertificateValidationCallback]::Ignore()

##### Prompt for NSX Server if neccessary
$storebegin = read-host "Provide First Store to Create"
$storeend = read-host "Provide Last Store to Create"
$NSXTServer = read-host "Provide NSX-T Server FQDN"


##### Gather Credentials for NSXT
$cred = Get-Credential

##### Build the Header for Authentication
$headerDictionary = @{}
    $base64cred = [system.convert]::ToBase64String(
        [system.text.encoding]::ASCII.Getbytes(
            "$($cred.GetNetworkCredential().username):$($cred.GetNetworkCredential().password)"
        )
    )
$headerDictionary.add("Authorization", "Basic $Base64cred")

#### Setup the NSX vars
$Timeout = "600"
$ContentType = "application/json"
$startip = "10.64.8.0"
$storearray = @("Stores:0:21","General_Network_Management:112:28","LWAPP_Network:128:26","Data_Client_Network:256:24","POS_Network:512:26","Embedded_Systems_Appliances_Network_1:576:26","Wired_Voice_Network:768:24","Wireless_Data_Network:1024:25","Wireless_Voice_Network:1152:26","Wireless_Other_Network:1216:26")

#### Check existing IP Sets
do {
    write-host "Loading existing IPSets"
    $URI = "/api/v1/ip-sets?cursor="+ $response.cursor
    $FullURI = "https://$($NSXTServer):443$($URI)"
    $Method = "get"

    $Splat = @{
            "method" = $Method;
            "headers" = $headerDictionary;
            "ContentType" = $ContentType;
            "uri" = $FullURI;
            "TimeoutSec" = $Timeout
        }

    ##### Go get the data via a rest call
    try
    {
        $response = invoke-restmethod @Splat
    }
    catch
    {
        $errorresponse = "Connection to NSX server $Server failed : $_."
        throw
    }
    $ipsets = $ipsets + $response.results.display_name
} until ($response.cursor -eq $null)


###Loop through stores
For ($i=[int]$storebegin; $i -le [int]$storeend; $i++) {
    $storeinc = ($i-1) * 2048

###Loop through each subnet within a store
    $storearray | ForEach-Object {
        $storenet, $storenetinc, $storenetcidr = $_.split(':')
        $storenetip=(Get-CalculatedIP $startip -ChangeValue ($storeinc + $storenetinc)).IPAddressToString

###Is this a Store or a subnet within a store
        if ($storenetinc -eq 0) {
            $tag = "Store_"+ '{0:d4}' -f $i
            $scope = "$storenet"
            $displayname=$tag
        }
        else {
            $tag = $storenet
            $scope = "Store_"+'{0:d4}' -f $i
            $displayname=$scope+"-"+$tag
        }

###Create IP Sets
        $URI = "/api/v1/ip-sets"
        $FullURI = "https://$($NSXTServer):443$($URI)"
        $Method = "post"

        $BodyDoc = @"
            {
            "resource_type": "IPSet",
            "ip_addresses": ["$storenetip/$storenetcidr"],
            "display_name": "IPSet-$displayname",
            "tags": [{"scope": "$scope","tag": "$tag"}]
            }
"@
        $Splat = @{
                "method" = $Method;
                "headers" = $headerDictionary;
                "ContentType" = $ContentType;
                "uri" = $FullURI;
                "TimeoutSec" = $Timeout;
                "Body" = $BodyDoc
            }

        ##### Go post the data via a rest call
        if ($ipsets.Contains("IPSet-$displayname")) {
            write-host "*** IPSet-$displayname already exists, not creating ***"
        } 
        else {
            write-host "Creating IPSet-$displayname"

            try
            {
                $response = invoke-restmethod @Splat
            }
            catch
            {
                $errorresponse = "Connection to NSX server $Server failed : $_."
                throw
            }
        }

###Create each store Groups
        $URI = "/policy/api/v1/infra/domains/default/groups/"+$displayname
        $FullURI = "https://$($NSXTServer):443$($URI)"
        $Method = "patch"
        $BodyDoc = @"
        {
            "expression": [
            {
              "member_type": "IPSet",
              "key": "Tag",
              "operator": "EQUALS",
              "value": "$scope|$tag",
              "resource_type": "Condition"
            }],
              "resource_type": "Group",
              "id": "$displayname",
              "display_name": "$displayname"
        }
"@
        $Splat = @{
                "method" = $Method;
                "headers" = $headerDictionary;
                "ContentType" = $ContentType;
                "uri" = $FullURI;
                "TimeoutSec" = $Timeout;
                "Body" = $BodyDoc
            }
        write-host "Creating Group $displayname"
        ##### Go patch the data via a rest call
        try
        {
            $response = invoke-restmethod @Splat
        }
        catch
        {
            $errorresponse = "Connection to NSX server $Server failed : $_."
            throw
        }

###Create all store Groups
        if ($scope -ne "Stores") {
            $URI = "/policy/api/v1/infra/domains/default/groups/Stores-"+$tag
            $FullURI = "https://$($NSXTServer):443$($URI)"
            $BodyDoc = @"
            {
                "expression": [
                {
                  "member_type": "IPSet",
                  "key": "Tag",
                  "operator": "EQUALS",
                  "value": "|$tag",
                  "resource_type": "Condition"
                }],
                  "resource_type": "Group",
                  "id": "Stores-$tag",
                  "display_name": "Stores-$tag"
            }
"@
            $Splat = @{
                    "method" = $Method;
                    "headers" = $headerDictionary;
                    "ContentType" = $ContentType;
                    "uri" = $FullURI;
                    "TimeoutSec" = $Timeout;
                    "Body" = $BodyDoc
                }
		    write-host "Creating Group Stores-$tag"
            ##### Go patch the data via a rest call
            try
            {
                $response = invoke-restmethod @Splat
            }
            catch
            {
                $errorresponse = "Connection to NSX server $Server failed : $_."
                throw
            }
        }
    }
    write-host "-------------------------------------------------------------------------"
    Start-Sleep -Second 10
}