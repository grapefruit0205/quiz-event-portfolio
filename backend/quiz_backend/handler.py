"""API Gateway REST proxy-shaped request handling, with injected local storage."""

import base64
import binascii
import json
import logging
import re
import uuid

from .quiz import (ApiError, MAX_BODY_BYTES, grade, parse_json, public_quiz,
                   utc_now, valid_identifier, validate_submission)

LOG = logging.getLogger("quiz_backend")
PLAYER_PATH = re.compile(r"/players/([A-Za-z0-9][A-Za-z0-9_-]{0,63})(/results)?")


def response(status: int, body: dict, request_id: str, replayed: bool = False) -> dict:
    return {"statusCode": status, "isBase64Encoded": False,
            "headers": {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff", "X-Request-Id": request_id,
                        "X-Idempotent-Replay": "true" if replayed else "false"},
            "body": json.dumps(body, ensure_ascii=False, allow_nan=False)}


def error_response(error: ApiError, request_id: str) -> dict:
    return response(error.status, {"error": {"code": error.code, "message": error.message},
                                   "request_id": request_id}, request_id)


def _principal(event: dict, principal_map: dict) -> str:
    context = event.get("requestContext")
    identity = context.get("identity") if isinstance(context, dict) else None
    principal = identity.get("userArn") if isinstance(identity, dict) else None
    if not isinstance(principal, str) or not principal:
        raise ApiError(401, "UNAUTHENTICATED", "인증된 테스트 사용자가 필요합니다.")
    player = principal_map.get(principal)
    if player is None:
        raise ApiError(403, "FORBIDDEN", "허용되지 않은 사용자입니다.")
    return player


def _body(event: dict) -> str:
    body = event.get("body")
    if not isinstance(body, str):
        raise ApiError(400, "INVALID_JSON", "JSON 문자열 본문이 필요합니다.")
    encoded = event.get("isBase64Encoded", False)
    if type(encoded) is not bool:
        raise ApiError(400, "INVALID_REQUEST", "isBase64Encoded는 bool이어야 합니다.")
    if encoded:
        if len(body) > ((MAX_BODY_BYTES + 2) // 3) * 4:
            raise ApiError(413, "BODY_TOO_LARGE", "본문은 16 KiB 이하여야 합니다.")
        try:
            body = base64.b64decode(body, validate=True).decode("utf-8")
        except (ValueError, binascii.Error, UnicodeError) as exc:
            raise ApiError(400, "INVALID_JSON", "유효한 UTF-8 본문이 필요합니다.") from exc
    return body


def build_handler(store, principal_map: dict[str, str], clock=utc_now):
    """The principal map is server configuration, never a client header/body."""
    principals = dict(principal_map)
    if not principals or not all(isinstance(k, str) and k and valid_identifier(v)
                                 for k, v in principals.items()):
        raise ValueError("An explicit principal -> player mapping is required.")

    def handle(event, context=None):
        request_id = str(uuid.uuid4())
        error_code = None
        try:
            if not isinstance(event, dict):
                raise ApiError(400, "INVALID_REQUEST", "요청 객체가 필요합니다.")
            player = _principal(event, principals)
            method, path = event.get("httpMethod"), event.get("path")
            if not isinstance(method, str) or not isinstance(path, str):
                raise ApiError(400, "INVALID_REQUEST", "httpMethod와 path가 필요합니다.")
            if event.get("queryStringParameters") or event.get("multiValueQueryStringParameters"):
                raise ApiError(400, "UNSUPPORTED_QUERY", "이번 API는 쿼리 파라미터를 받지 않습니다.")
            if path == "/quiz":
                if method != "GET":
                    raise ApiError(405, "METHOD_NOT_ALLOWED", "GET을 사용하세요.")
                result = response(200, public_quiz(), request_id)
            else:
                match = PLAYER_PATH.fullmatch(path)
                if match is None:
                    raise ApiError(404, "NOT_FOUND", "없는 API 경로입니다.")
                owner, action = match.groups()
                # Ownership must be checked before parsing submission or reading ANY event.
                if player != owner:
                    raise ApiError(403, "FORBIDDEN", "다른 사용자의 데이터에는 접근할 수 없습니다.")
                if action is None and method == "GET":
                    result = response(200, store.get_player(owner), request_id)
                elif action == "/results" and method == "POST":
                    headers = event.get("headers") or {}
                    if not isinstance(headers, dict):
                        raise ApiError(400, "INVALID_REQUEST", "headers 객체가 필요합니다.")
                    types = [v for k, v in headers.items() if k.lower() == "content-type"]
                    if (len(types) != 1 or not isinstance(types[0], str)
                            or types[0].split(";", 1)[0].strip().lower() != "application/json"):
                        raise ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Content-Type: application/json을 사용하세요.")
                    submission = validate_submission(parse_json(_body(event)))
                    correct, score = grade(submission)
                    saved, replayed = store.submit(owner, submission, correct, score, clock())
                    result = response(200 if replayed else 201, saved, request_id, replayed)
                else:
                    raise ApiError(405, "METHOD_NOT_ALLOWED", "이 경로에서 허용되지 않은 메서드입니다.")
        except ApiError as exc:
            error_code = exc.code
            result = error_response(exc, request_id)
        except Exception as exc:
            # Never log request bodies, authorization headers, answer keys or exception text.
            error_code = "INTERNAL_ERROR"
            LOG.error(json.dumps({"request_id": request_id, "error_type": type(exc).__name__}))
            result = error_response(ApiError(500, error_code, "내부 오류가 발생했습니다."), request_id)
        LOG.info(json.dumps({"request_id": request_id, "status": result["statusCode"],
                             "error_code": error_code}))
        return result

    return handle


def lambda_handler(event, context):
    """Fail closed until Step 3/4 wires DynamoDB and verified AWS principal mapping.

    Do NOT deploy the local SQLite adapter to Lambda. Local execution uses
    build_handler explicitly; AWS storage/identity integration is not implemented yet.
    """
    return error_response(ApiError(503, "DEPLOYMENT_NOT_CONFIGURED",
                                  "Step 3/4의 DynamoDB·IAM 연결이 필요합니다."), str(uuid.uuid4()))
