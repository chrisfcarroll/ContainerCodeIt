When the image is rebuilt by calling code-it  with -buildImage, there is a question of whether or not to update the code agents by updating the cache-bust '# last changed' elements.

Add -updateAndBuildImage /  --update-and-build-image to code-it.ps1 and code-it.sh, which do almost the same thing as -buildImage, but in addition they will do something like:

(get-content Dockerfile) -replace "# last changed \d\d\d\d-\d\d-\d\d",("# last changed "+[DateTime]::Today.ToString('yyyy-MM-dd')) | Set-Content Dockerfile

or the bash equivalent for code-it.sh
