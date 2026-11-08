import json
import os
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Literal

import boto3
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

TABLA_PLANES = os.environ.get("TABLA_PLANES", "lab2-planes")
TABLA_INGREDIENTES = os.environ.get("TABLA_INGREDIENTES", "lab2-ingredientes")
COLA_URL = os.environ.get("COLA_URL", "")
REGION = os.environ.get("AWS_REGION", "us-east-2")

dynamodb = boto3.resource("dynamodb", region_name=REGION)
tabla_planes = dynamodb.Table(TABLA_PLANES)
tabla_ingredientes = dynamodb.Table(TABLA_INGREDIENTES)
sqs = boto3.client("sqs", region_name=REGION)

app = FastAPI(title="planes-web")


class DatosPlan(BaseModel):
    peso: float = Field(gt=20, lt=300, description="kg")
    talla: float = Field(gt=100, lt=250, description="cm")
    edad: int = Field(ge=15, le=100)
    sexo: Literal["M", "F"]
    actividad: Literal["sedentario", "ligero", "moderado", "intenso", "muy_intenso"] = "moderado"
    objetivo: Literal["perder_grasa", "mantener", "ganar_musculo"] = "mantener"


@app.middleware("http")
async def log_peticion(request: Request, call_next):
    inicio = time.time()
    respuesta = await call_next(request)
    ms = (time.time() - inicio) * 1000
    print(f"{request.method} {request.url.path} {respuesta.status_code} {ms:.1f} ms", flush=True)
    return respuesta


@app.get("/salud")
def salud():
    return {"estado": "ok", "app": "planes-web"}


@app.post("/planes", status_code=202)
def crear_plan(datos: DatosPlan):
    plan_id = str(uuid.uuid4())
    datos_dict = datos.model_dump()

    # DynamoDB no acepta float: se convierte a Decimal pasando por str
    item = {
        "id": plan_id,
        "estado": "pendiente",
        "creado": datetime.now(timezone.utc).isoformat(),
        "datos": json.loads(json.dumps(datos_dict), parse_float=Decimal),
    }
    tabla_planes.put_item(Item=item)

    sqs.send_message(
        QueueUrl=COLA_URL,
        MessageBody=json.dumps({"id": plan_id, "datos": datos_dict}),
    )
    return {"id": plan_id, "estado": "pendiente"}


@app.get("/planes/{id}")
def obtener_plan(id: str):
    respuesta = tabla_planes.get_item(Key={"id": id})
    if "Item" not in respuesta:
        raise HTTPException(status_code=404, detail="Plan no encontrado")
    return respuesta["Item"]


@app.get("/ingredientes")
def listar_ingredientes():
    respuesta = tabla_ingredientes.scan()
    items = respuesta["Items"]
    while "LastEvaluatedKey" in respuesta:
        respuesta = tabla_ingredientes.scan(ExclusiveStartKey=respuesta["LastEvaluatedKey"])
        items.extend(respuesta["Items"])
    return {"total": len(items), "ingredientes": items}
