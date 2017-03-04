[cmdletbinding()]
param(
    [switch]$UseImageCache
)

function Exec([scriptblock]$cmd, [string]$errorMessage = "Error executing command: " + $cmd) {
    & $cmd
    if ($LastExitCode -ne 0) {
        throw $errorMessage
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($UseImageCache) {
    $optionalDockerBuildArgs=""
}
else {
    $optionalDockerBuildArgs = "--no-cache"
}

$dockerRepo = "microsoft/dotnet"
$dirSeparator = [IO.Path]::DirectorySeparatorChar
$repoRoot = Split-Path -Parent $PSScriptRoot
$testFilesPath = "$PSScriptRoot$dirSeparator"
$platform = docker version -f "{{ .Server.Os }}"

if ($platform -eq "windows") {
    $imageOs = "nanoserver"
    $tagSuffix = "-nanoserver"
    $containerRoot = "C:\"
    $platformDirSeparator = '\'
}
else {
    $imageOs = "debian"
    $tagSuffix = ""
    $containerRoot = "/"
    $platformDirSeparator = '/'
}

# Loop through each sdk Dockerfile in the repo and test the sdk and runtime images.
Get-ChildItem -Path $repoRoot -Recurse -Filter Dockerfile |
    where DirectoryName -like "*${dirSeparator}${imageOs}${dirSeparator}sdk" |
    foreach {
        $sdkTag = $_.DirectoryName.
                Replace("$repoRoot$dirSeparator", '').
                Replace("$dirSeparator$imageOs", '').
                Replace($dirSeparator, '-') +
            $tagSuffix
        $fullSdkTag = "${dockerRepo}:${sdkTag}"
        $baseTag = $fullSdkTag.TrimEnd($tagSuffix).TrimEnd("-sdk")

        $timeStamp = Get-Date -Format FileDateTime
        $appName = "app$timeStamp".ToLower()
        $buildImage = "sdk-build-$appName"
        $dotnetNewParam = "console --framework netcoreapp$($sdkTag.Split('-')[0])"

        Write-Host "----- Testing create, restore and build with $fullSdkTag with image $buildImage -----"
        Try {
            exec { (Get-Content ${testFilesPath}Dockerfile.test).Replace("{image}", $fullSdkTag).Replace("{dotnetNewParam}", $dotnetNewParam) `
                | docker build $optionalDockerBuildArgs -t $buildImage -
            }

            Write-Host "----- Running app built on $fullSdkTag -----"
            exec { docker run --rm $buildImage dotnet run }

            $framworkDepVol = "framework-dep-publish-$appName"
            Write-Host "----- Publishing framework-dependant app built on $fullSdkTag to volume $framworkDepVol -----"
            Try {
                exec { docker run --rm `
                    -v ${framworkDepVol}:"${containerRoot}volume" `
                    $buildImage `
                    dotnet publish -o ${containerRoot}volume 
                }

                Write-Host "----- Testing on $baseTag-runtime$tagSuffix with $sdkTag framework-dependent app -----"
                exec { docker run --rm `
                    -v ${framworkDepVol}":${containerRoot}volume" `
                    "$baseTag-runtime$tagSuffix" `
                    dotnet "${containerRoot}volume${platformDirSeparator}test.dll"
                }
            }
            Finally {
                docker volume rm $framworkDepVol
            }

            if ($platform -eq "linux") {
                $selfContainedImage = "self-contained-build-${buildImage}"

                Write-Host "----- Creating publish-image for self-contained app built on $fullSdkTag -----"
                Try {
                    exec { (Get-Content ${testFilesPath}Dockerfile.linux.publish).Replace("{image}", $buildImage) `
                        | docker build $optionalDockerBuildArgs -t $selfContainedImage -
                    }

                    $selfContainedVol = "self-contained-publish-$appName"
                    Write-Host "----- Publishing self-contained published app built on $fullSdkTag to volume $selfContainedVol using image $selfContainedImage -----"
                    Try {
                        exec { docker run --rm `
                            -v ${selfContainedVol}":${containerRoot}volume" `
                            $selfContainedImage `
                            dotnet publish -r debian.8-x64 -o ${containerRoot}volume
                        }

                        Write-Host "----- Testing $baseTag-runtime-deps$tagSuffix with $sdkTag self-contained app -----"
                        exec { docker run -t --rm `
                            -v ${selfContainedVol}":${containerRoot}volume" `
                            ${baseTag}-runtime-deps$tagSuffix `
                            ${containerRoot}volume${platformDirSeparator}test
                        }
                    }
                    Finally {
                        docker volume rm $selfContainedVol
                    }
                }
                Finally {
                    docker image rm $selfContainedImage
                }
            }
        }
        Finally {
            docker image rm $buildImage
        }
    }
