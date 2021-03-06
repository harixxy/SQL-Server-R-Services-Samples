<#
.SYNOPSIS
Script to trian and test thecustomer churn template with SQL + MRS

.DESCRIPTION
This script will show the E2E work flow of customer churn machine learning
templates with Microsoft SQL 2016 and Microsoft R services. 

Switch parameter ResetParmOnly allows you to reset the SQL database name.

For the detailed description, please read README.md.
#>
[CmdletBinding()]
param(
# SQL server address
[parameter(Mandatory=$true,ParameterSetName = "Train_test")]
[ValidateNotNullOrEmpty()] 
[String]    
$ServerName = "",

# SQL server database name
[parameter(Mandatory=$true,ParameterSetName = "Train_test")]
[ValidateNotNullOrEmpty()]
[String]
$DBName = "",

# Churn Period
[parameter(Mandatory=$false,ParameterSetName = "Train_test")]
[Int]
$ChurnPeriodVal = 21,

# Churn threshold
[parameter(Mandatory=$false,ParameterSetName = "Train_test")]
[Int]
$ChurnThresholdVal = 0,

# Switch to scoring 
[parameter(Mandatory=$false,ParameterSetName = "ResetParams")]
[ValidateNotNullOrEmpty()]
[Switch]
$ResetParamsOnly
)
##########################################################################
# Script level variables
##########################################################################
$scriptPath = Get-Location
$filePath = $scriptPath.Path+ "\"
$parentPath = Split-Path -parent $scriptPath
$defaultDBName = "DefaultDBName"
##########################################################################
# Function wrapper to invoke SQL command
##########################################################################
function ExecuteSQL
{
param(
[String]
$sqlscript
)
    Invoke-Sqlcmd -ServerInstance $ServerName  -Database $DBName -Username $username -Password $password -InputFile $sqlscript -QueryTimeout 200000
}

##########################################################################
# Update the churning related parameters 
##########################################################################
function SetChurnParams
{
param(
[Int]
$churnPeriodVal,
[Int]
$churnThresholdVal
)  
    $file = $filePath + "createDBTables.sql"
    $r = "^(\s*insert.*)(values)\s+(.*)"
    $pair = "($churnPeriodVal, $churnThresholdVal)"
    # Udpate the Database name 
    $content = Get-Content $file     
    $content | Foreach-Object {
        $_ -replace $r, "`$1 `$2 $pair"
    } | Set-Content $file
}

##########################################################################
# Update the SQL database name which will be used for workflow
##########################################################################
function SetParamValue
{
param(
[String]
$targetDbname
)
    # Get the current parameter values
    $rUse = "\s*use\s+\[(.*)\]$"   
  
    $files = $filePath + "*.sql"
    $listfiles = Get-ChildItem $files -Recurse

    # Udpate the SQL related parameters in each SQL script file
    foreach ($file in $listfiles)
    {        
        (Get-Content $file) | Foreach-Object {
            $_ -replace $rUse, "use [$targetDbname]"
        } | Set-Content $file
    }
}

##########################################################################
# Reset the SQL related parameters
##########################################################################
if($ResetParamsOnly -eq $true)
{
    Write-Host -ForeGroundColor 'green'("Reset the SQL related parameters to default values...")
    Read-Host "Press any key to continue..."
    SetParamValue $defaultDBName
    exit
}

##########################################################################
# Get the credential of SQL user
##########################################################################
Write-Host -foregroundcolor 'green' ("Please enter the credential for Database {0} of SQL server {1}" -f $DBName, $ServerName)
$username = Read-Host 'Username:'
$pwd = Read-Host 'Password:' -AsSecureString
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))

##########################################################################
# Update the SQL scripts
##########################################################################
Write-Host -foregroundcolor 'green' ("Using SQL DB: {0} and User: {1}?" -f $DBName, $username)
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'

if ($ans -eq 'y' -or $ans -eq 'Y')
{
    Write-Host -ForeGroundColor 'green' ("Update SQL related parameters in all SQL scripts...")
    SetParamValue $DBName
    SetChurnParams $ChurnPeriodVal $ChurnThresholdVal
    Write-Host -ForeGroundColor 'green' ("Done...Update SQL related parameters in all SQL scripts")
}

##########################################################################
# Create tables for train data and populate the table with csv files.
##########################################################################
Write-Host -ForeGroundColor 'green' ("Step 1: Create and populate SQL tables in Database {0}" -f $DBName)
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 

if ($ans -eq 'y' -or $ans -eq 'Y')
{
    try
    {
        # create training and test tables
        Write-Host -ForeGroundColor 'green' ("Create SQL tables:")
        $script = $filePath + "createDBtables.sql"
        ExecuteSQL $script
    
        Write-Host -ForeGroundColor 'green' ("Populate SQL tables: Activities and Users")
        $dataList = "Activities", "Users"
		
		# upload csv files into SQL tables
        foreach ($dataFile in $dataList)
        {
            $destination = $parentPath + "/data/" + $dataFile + ".csv"
            Write-Host -ForeGroundColor 'magenta'("    Populate SQL table: {0}..." -f $dataFile)
            $tableName = $DBName + ".dbo." + $dataFile
            $tableSchema = $parentPath + "/data/" + $dataFile + ".xml"
            bcp $tableName format nul -c -x -f $tableSchema  -U $username -S $ServerName -P $password  -t ','
            Write-Host -ForeGroundColor 'magenta'("    Loading {0} to SQL table..." -f $dataFile)
            bcp $tableName in $destination -t ',' -S $ServerName -f $tableSchema -F 1 -C "RAW" -b 20000 -U $username -P $password
            Write-Host -ForeGroundColor 'magenta'("    Done...Loading {0} to SQL table..." -f $dataFile)
        }
    }
    catch
    {
        Write-Host -ForegroundColor DarkYellow "Exception in populating train and test database tables:"
        Write-Host -ForegroundColor Red $Error[0].Exception 
        throw
    }
}

##########################################################################
# Create and execute the stored procedure for feature engineering and tags
##########################################################################
Write-Host -foregroundcolor 'green' ("Step 2: Data tagging and feature engineering")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create and execute the stored procedure for feature engineering
    $script = $filePath + "CreateFeatures.sql"
    ExecuteSQL $script
	

    # create and execute the stored procedure for tags
    $script = $filePath + "CreateTag.sql"
    ExecuteSQL $script
}

###########################################################################
# Create and execute the stored procedures for training an open-source R 
# or Microsoft R model
###########################################################################
Write-Host -foregroundcolor 'green' ("Step 3a: Training an open-source model")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create and execute the stored procedure for an open-source R model
    $script = $filePath + "TrainModelR.sql"
    ExecuteSQL $script
}

Write-Host -foregroundcolor 'green' ("Step 3b: Training a Microsoft R model")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create and execute the stored procedure for a Microsoft R model
    $script = $filePath + "TrainModelRx.sql"
    ExecuteSQL $script
}

###########################################################################
# Create and execute the stored procedures for prediction based on 
# previously trained open-source R or Microsoft R model
###########################################################################
Write-Host -foregroundcolor 'green' ("Step 4a: Predicting based on the open-source model")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create and execute the stored procedure for an open-source R model
    $script = $filePath + "PredictR.sql"
    ExecuteSQL $script
}

Write-Host -foregroundcolor 'green' ("Step 4b: Predicting based on the Microsoft R model")
$ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
if ($ans -eq 'E' -or $ans -eq 'e')
{
    return
} 
if ($ans -eq 'y' -or $ans -eq 'Y')
{
    # create and execute the stored procedure for a Microsoft R model
    $script = $filePath + "PredictRx.sql"
    ExecuteSQL $script
}