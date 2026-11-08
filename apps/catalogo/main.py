import os
import time

import boto3
from fastapi import FastAPI, HTTPException, Request

TABLA_INGREDIENTES = os.environ.get("TABLA_INGREDIENTES", "lab2-ingredientes")
REGION = os.environ.get("AWS_REGION", "us-east-2")

tabla = boto3.resource("dynamodb", region_name=REGION).Table(TABLA_INGREDIENTES)

app = FastAPI(title="catalogo")


@app.middleware("http")
async def log_peticion(request: Request, call_next):
    inicio = time.time()
    respuesta = await call_next(request)
    ms = (time.time() - inicio) * 1000
    print(f"{request.method} {request.url.path} {respuesta.status_code} {ms:.1f} ms", flush=True)
    return respuesta


@app.get("/salud")
def salud():
    return {"estado": "ok", "app": "catalogo"}


@app.get("/ingredientes")
def listar_ingredientes():
    respuesta = tabla.scan()
    items = respuesta["Items"]
    # scan devuelve como máximo 1 MB por página
    while "LastEvaluatedKey" in respuesta:
        respuesta = tabla.scan(ExclusiveStartKey=respuesta["LastEvaluatedKey"])
        items.extend(respuesta["Items"])
    return {"total": len(items), "ingredientes": items}


@app.get("/ingredientes/{id}")
def obtener_ingrediente(id: str):
    respuesta = tabla.get_item(Key={"id": id})
    if "Item" not in respuesta:
        raise HTTPException(status_code=404, detail="Ingrediente no encontrado")
    return respuesta["Item"]
