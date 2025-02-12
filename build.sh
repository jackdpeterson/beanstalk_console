docker buildx build \
--sbom=true \
--provenance=true \
--output=type=image,push=true \
--platform=linux/amd64 \
--tag jackdpeterson/beanstalk_console:1.7.21-8.3 \
--file "Dockerfile" .