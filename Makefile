FUNCTION_NAME ?= my-function-name

.PHONY: dev build deploy

dev:
	uvicorn app.main:app --reload

build:
	rm -rf ./_package lambda.zip
	poetry export --without-hashes --format=requirements.txt > requirements.txt
	pip install \
		--platform manylinux2014_x86_64 \
		--implementation cp \
		--only-binary=:all: \
		-r requirements.txt \
		--target ./_package \
		--upgrade
	rm requirements.txt
	cp -R ./app ./_package/app
	cp handler.py ./_package/
	cd _package && zip -r ../lambda.zip . && cd ..
	rm -rf ./_package

deploy:
	aws lambda update-function-code \
		--function-name $(FUNCTION_NAME) \
		--zip-file fileb://lambda.zip
