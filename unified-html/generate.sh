#!/usr/bin/env bash

SRC1="../osi/*.html"
SRC2="../spdx/*.html"

# Copy the two sources to this dir, while the results from SRC2 override the already existing ones
cp -- $SRC1 .
cp -- $SRC2 .

# Create index.html
licenses=$(ls -- *.html | grep -Ev "^index.html$")
licenses=""
licenses_html=""
for file in *html; do
  if [[ $file == "index.html" ]]; then
    continue
  fi
  licenses_html+="<li><a href='$file'>${file//.html/}</li>"
done

# licenses_html=""

# for lic in $licenses; do
#   name=${lic//.html/}
#   licenses_html+="<li><a href='$lic'>$name</li>"
# done

cat >index.html <<EOF
<html>
<head>
<title>LDBcollector data</title>
</head>
<body>
<h1>Licenses</h1>
<ul>
${licenses_html}
</ul>
</body>
</html>
EOF
