FUNCTION_NAME ?= my-function-name

.PHONY: dev build deploy

dev:
	uvicorn app.main:app --reload

build:
	rm -rf ./_package lambda.zip
	uv export --no-dev --no-hashes -o requirements.txt
	uv pip install \
		--python-platform x86_64-unknown-linux-gnu \
		--python 3.13 \
		--no-installer-metadata \
		-r requirements.txt \
		--target ./_package
	rm requirements.txt
	cp -R ./app ./_package/app
	cp handler.py ./_package/
	cd _package && zip -r ../lambda.zip . && cd ..
	rm -rf ./_package

deploy:
	aws lambda update-function-code \
		--function-name $(FUNCTION_NAME) \
		--zip-file fileb://lambda.zip
