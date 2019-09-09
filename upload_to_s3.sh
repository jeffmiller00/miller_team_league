git push origin master
jekyll clean
jekyll build
aws s3 rm s3://millerteamleague.com --recursive
aws s3 cp ./_site/. s3://www.millerteamleague.com --recursive --exclude "*.sh"
