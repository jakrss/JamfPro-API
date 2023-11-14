#####################################################################
#                                                                   #
#                Created by Jacob Huggins 11.03.2022                #
#                           Catalytic IT                            #
#          Calls Jamf API for each CSV listed instance to enable    #
#                 and disable daily restrictions                    #
#                                                                   #
#                        Version 1.0.0                              #
#####################################################################
#
# Takes input from CSVs in a folder location and performs API calls for restrictions - "C:\Scripts\JamfRestrictions\" configured under Globals
#jss,apiuser,apipass,whitelistid,restrictionsid,groupid,groupname,usergroupid,usergroupname,emptyid,emptyname,commands,manualdates
#jss - JSS URL (eg. https://instancename.jamfcloud.com/)
#apiuser - JamfPro Username
#apipass - Cleartext password for API user(restrict this use to only functions required)
#whitelistid - Config Profile ID of an App whitelist to apply during school hours
#restrictionsid - Config Profile ID of restrictions to apply during school hours
#groupid - GroupID of a device group in which the profiles will be scoped to during school hours.
#groupname - Display Name of target restrictions group
#usergroupid - GroupID of a user group in which restrictions will not apply. (exclusion group)
#usergroupname - Display Name of a user group
#emptyid - GroupID of an Empty device group (static group with no members) - this is required for unscoping as simply removing the scoped group doesn't always force the removal of the profile instantly.
#emptyname - Display Name of an Empty group
#commands specifies remote commands to push to the defined groupid (comma seperated)
#manual dates defines which dates not to run the scoping on (comma seperated)

#### EXAMPLE CSV #####
#jss,apiuser,apipass,whitelistid,restrictionsid,groupid,groupname,usergroupid,usergroupname,emptyid,emptyname,commands,manualdates
#https://instancename.jamfcloud.com/,UserNameHere,PasswordHere,41,42,26,Student Group,3,Excluded Users Group,42,Empty,SettingsEnableBluetooth,"01/01/23,05/06/23"
#

#### TO DO ####
#
# code checkPublic() to check for public holidays
#

### FUNCTION LIST ####
#
# isItASchoolDay()
#   Will check all checking functions to determine if school is open / restrictions should run
# checkTerm()
#   Uses DoE website to determine if it is currently within school term
# checkPublic()
#   Uses WA Gov website to determine if it is currently a public holiday
# checkManual()
#   Uses a manually defined CSV to determine school closure dates
#
# getBearerToken(url, user, password)
#   Gets the auth token for later use
# getMobileGroupMembership(url, token, group)
#   Returns array containing all devices in a group
# sendRemoteCommandToGroup(url, token, command, group)
#   Sends a remote command such as enable bluetooth to a group (This calls getMobileGroupMembership and sendMobileRemoteCommand)
# sendMobileRemoteCommand(url, token, command, device)
#   Sends a remote command to a specific device (called via loop from sendcommandtogroup)
# modifyConfigProfileScope(url, token, profileid, jamfinfo, boolean)
#   Modifies the scoping of a config profile, set boolean to True for scoping, and False to unscope
#


#####################Globals################################
$Today      = Get-Date
$jamfPath   = "C:\Scripts\JamfRestrictions\"

class JamfInstance {
	[String]$jss                #JSS URL https://*.jamfcloud.com/
	[String]$apiuser            #
	[String]$apipass            #
}

class JamfInfo {
    [String]$whitelistid        #Profile ID of the App Whitelist
    [String]$restrictionsid     #Profile ID of the Restrictions Profile
    [String]$groupid            #Group ID of scoping group
    [String]$groupname          #Group Name of scoping group
    [String]$usergroupid        #User Group ID of users to exclude from restrictions
    [String]$usergroupname      #User Group Name of users to exclude from restrictions
    [String]$emptyid            #Group ID of an empty group to assist with unscoping
    [String]$emptyname          #Group Name of an empty group to assist with unscoping
    [String]$commands           #Commands to push to the scoped group
    [String]$manualdates        #Manual dates defined not to run script on
}

class Jamf {
	[JamfInstance]$instance    
	[JamfInfo]$info           
}


#####################Code Start################################

function init {
    $JamfSuite               = [Jamf]::new()
    $JamfSuite.instance      = [JamfInstance]::new()
    $JamfSuite.info          = [JamfInfo]::new()

    Get-ChildItem –Path $jamfPath -Filter *.csv | Foreach-Object {
        $csv = Import-Csv $_.FullName
        foreach ($item in $csv) {
            $JamfSuite.instance.jss = $item.jss
            $JamfSuite.instance.apiuser = $item.apiuser
            $JamfSuite.instance.apipass = $item.apipass
            $JamfSuite.info.whitelistid = $item.whitelistid
            $JamfSuite.info.restrictionsid = $item.restrictionsid
            $JamfSuite.info.groupid = $item.groupid
            $JamfSuite.info.groupname = $item.groupname
            $JamfSuite.info.usergroupid = $item.usergroupid
            $JamfSuite.info.usergroupname = $item.usergroupname
            $JamfSuite.info.emptyid = $item.emptyid
            $JamfSuite.info.emptyname = $item.emptyname
            $JamfSuite.info.commands = $item.commands
            $JamfSuite.info.manualdates = $item.manualdates

            call $JamfSuite
        }
    }
}

function call ([Jamf]$jamf) {
    $jamfurl = $jamf.instance.jss

	if (isItASchoolDay $jamf.info.manualdates) {
        #Get the Auth Token for future API Calls
        $token = getBearerToken $jamf.instance

        switch($Today.ToString('tt')) { 
            'AM'{
                #Scope Profiles
                if ($jamf.info.whitelistid.Length -ne 0) { modifyConfigProfileScope $jamfurl $token $jamf.info.whitelistid $jamf.info $True }
                if ($jamf.info.restrictionsid.Length -ne 0) { modifyConfigProfileScope $jamfurl $token $jamf.info.restrictionsid $jamf.info $True }
            }
            'PM'{
                #Unscope Profiles
                if ($jamf.info.whitelistid.Length -ne 0) { modifyConfigProfileScope $jamfurl $token $jamf.info.whitelistid $jamf.info $False }
                if ($jamf.info.restrictionsid.Length -ne 0) { modifyConfigProfileScope $jamfurl $token $jamf.info.restrictionsid $jamf.info $False }
            }
        }

        #Send management commands to devices in target group. ie. EnableBluetooth
        if ($jamf.info.commands.Length -ne 0) {
            foreach ($command in $jamf.info.commands.Split(",")) {
                sendRemoteCommandToGroup $jamfurl $token $jamf.info.groupid $command
            }
        }
    }
}

function isItASchoolDay([string]$manualdates) {

    if ((checkTerm) -and !(checkPublic) -and (checkManual $manualdates)) {
        return $True #School should be open
    } else {
        return $False #School is closed
    }

}

function checkTerm() {
    $HTML = Invoke-RestMethod 'https://www.education.wa.edu.au/future-term-dates/'
    $Pattern = '<div class="eds-c-content-view"> <h4>' + $(Get-Date).Year + ' Term dates<\/h4> <table class="eds-c-table--term-dates eds-o-table"> <thead> <tr> <th colspan="2">Semester 1<\/th> <\/tr> <\/thead> <tbody> <tr class="odd"> <td>Term 1<\/td> <td>(?<term1>.*)<\/td> <\/tr> <tr> <td>Break<\/td> <td>(?<break1>.*)<\/td> <\/tr> <tr class="odd"> <td>Term 2<\/td> <td>(?<term2>.*)<\/td> <\/tr> <tr> <td>Break<\/td> <td>(?<break2>.*)<\/td> <\/tr> <\/tbody> <\/table> <table class="eds-c-table--term-dates eds-o-table"> <thead> <tr> <th colspan="2">Semester 2<\/th> <\/tr> <\/thead> <tbody> <tr class="odd"> <td>Term 3<\/td> <td>(?<term3>.*)<\/td> <\/tr> <tr> <td>Break<\/td> <td>(?<break3>.*)<\/td> <\/tr> <tr class="odd"> <td>Term 4<\/td> <td>(?<term4>.*)<\/td>'
    $AllMatches = ($HTML | Select-String $Pattern -AllMatches).Matches
    $AllMatches = ([regex]$Pattern).Matches($HTML)
    
    $TermList = @()
        $TermOne = ($AllMatches.Groups.Where{$_.Name -like 'term1'}).Value.Split('<')[0]
        $TermTwo = ($AllMatches.Groups.Where{$_.Name -like 'term2'}).Value.Split('<')[0]
        $TermThree = ($AllMatches.Groups.Where{$_.Name -like 'term3'}).Value.Split('<')[0]
        $TermFour = ($AllMatches.Groups.Where{$_.Name -like 'term4'}).Value.Split('<')[0]
    $TermList = $TermOne, $TermTwo, $TermThree, $TermFour
    
    foreach ($Term in $TermList) {
        $startday = $Term.Split('-')[0].Trim()
        $endday = $Term.Split('-')[-1].Trim()

    ######## This is stupid, I shouldn't have to do this but WA Govt decided to write Thursday as Thurs instead of Thu for 2023
        if ($startday.Split(' ')[0].Length -gt 3) {
            $split = $startday.Split(' ')
            $startday = $split[0][0] + $split[0][1] + $split[0][2] + " " + $split[1] + " " + $split[2]
        }

        if ($endday.Split(' ')[0].Length -gt 3) {
            $split = $endday.Split(' ')
            $endday = $split[0][0] + $split[0][1] + $split[0][2] + " " + $split[1] + " " + $split[2]
        }
    #########

        $start = [Datetime]::ParseExact(($startday + " " + $(Get-Date).Year), 'ddd d MMMM yyyy', $null)
        $end = [Datetime]::ParseExact(($endday + " " + $(Get-Date).Year), 'ddd d MMMM yyyy', $null)
    
        if (($Today -ge $start) -and ($Today -le $end)) {
            #It is within term time, check for weekends.
            if (([String]$Today.DayOfWeek -ne "Saturday") -and ([String]$Today.DayOfWeek -ne "Sunday")) {
                return $True #It is a weekday
            } else {
                #return $False #It is the weekend
            }
        } else {
            #return $False #It is a school break
        }
    }
    return $False #It made it through the for loop without returning true, it must not be term time..
}

function checkPublic() {
    #still need to code this, for now assume it's not a public holiday
    return $False
}

function checkManual([string]$dates) {
    foreach ($date in $dates.Split(",")) {
        if ([Datetime]::ParseExact($date, 'd/M/yy', $null) -eq $Today.Date) {
            return $False #Matched manual date - lets not run the restrictions
        }
    }
    return $True #No dates matched
}

function getBearerToken([JamfInstance]$jamf) {
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($jamf.apiuser):$($jamf.apipass)"))
    $jss = $jamf.jss
    $Header = @{
        Authorization = "Basic $base64AuthInfo"
    }
    
    $Parameters = @{
        Method      = "POST"
        Uri         = "$jss/api/v1/auth/token"
        Headers     = $Header
    }
    
    $authToken = Invoke-RestMethod @Parameters

    $token = $authToken.token

    #Clearing credentials variables
    $jamf.apiuser = "" 
    $jamf.apipass = ""
    return $token
}

function getMobileGroupMembership([string]$jamfurl, [string]$jamftoken, [string]$groupid) {
    $Header = @{
        "authorization" = "Bearer $jamftoken"
    }
    
    $Parameters = @{
        Method      = "GET"
        Uri         = "$jamfurl/JSSResource/mobiledevicegroups/id/$groupid"
        Headers     = $Header
        ContentType = "application/json"
    }
    
    $Group = Invoke-RestMethod @Parameters

    return $Group.mobile_device_group.mobile_devices.mobile_device
}

function sendRemoteCommandToGroup([string]$jamfurl, [string]$jamftoken, [string]$groupid, [string]$command) {
    $Devices = getMobileGroupMembership $jamfurl $jamftoken $groupid

    foreach ($Device in $Devices) {
        sendMobileRemoteCommand $jamfurl $jamftoken $command $Device.id
    }
}

function sendMobileRemoteCommand([string]$jamfurl, [string]$jamftoken, [string]$command, [string]$deviceid) {
    $BodyXml = "<mobile_device_command><general><command>$command</command></general><mobile_devices><mobile_device><id>$deviceid</id></mobile_device></mobile_devices></mobile_device_command>"

    $Header = @{
        "authorization" = "Bearer $jamftoken"
    }
    
    $Parameters = @{
        Method      = "POST"
        Uri         = "$jamfurl/JSSResource/mobiledevicecommands/command"
        Headers     = $Header
        ContentType = "application/xml"
        Body        = $BodyXml
    }

    Invoke-RestMethod @Parameters
}

function modifyConfigProfileScope([string]$jamfurl, [string]$jamftoken, [string]$profileid, [JamfInfo]$info, [boolean]$scope) {
    if ($scope) {
        if ($info.usergroupid.Length -eq 0) {
            $BodyXml = "<configuration_profile><scope><mobile_device_groups><mobile_device_group><id>" + $info.groupid + "</id><name>" + $info.groupname + "</name></mobile_device_group></mobile_device_groups></scope></configuration_profile>"
        } else {
            $BodyXml = "<configuration_profile><scope><mobile_device_groups><mobile_device_group><id>" + $info.groupid + "</id><name>" + $info.groupname + "</name></mobile_device_group></mobile_device_groups><exclusions><jss_user_groups><user_group><id>" + $info.usergroupid + "</id><name>" + $info.usergroupname + "</name></user_group></jss_user_groups></exclusions></scope></configuration_profile>"
        }
    } else {
        $BodyXml = "<configuration_profile><scope><mobile_device_groups><mobile_device_group><id>" + $info.emptyid + "</id><name>" + $info.emptyname + "</name></mobile_device_group></mobile_device_groups></scope></configuration_profile>"
    }

    $Header = @{
        "authorization" = "Bearer $jamftoken"
    }
    
    $Parameters = @{
        Method      = "PUT"
        Uri         = "$jamfurl/JSSResource/mobiledeviceconfigurationprofiles/id/$profileid"
        Headers     = $Header
        ContentType = "application/xml"
        Body        = $BodyXml
    }
    
    Invoke-RestMethod @Parameters
}

init