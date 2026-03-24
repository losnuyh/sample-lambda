import os

import boto3


def _load() -> dict:
    ssm = boto3.client("ssm")
    prefix = os.environ["SSM_PREFIX"]
    response = ssm.get_parameters_by_path(Path=prefix, WithDecryption=True)
    return {p["Name"].removeprefix(prefix + "/"): p["Value"] for p in response["Parameters"]}


config = _load()
