import os
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

TABLA_PLANES = os.environ.get("TABLA_PLANES", "lab2-planes")
REGION = os.environ.get("AWS_REGION", "us-east-2")
# Segundos que dura la simulación del optimizador (se puede bajar para pruebas locales)
SEGUNDOS_CPU = float(os.environ.get("SEGUNDOS_CPU", "15"))

tabla_planes = boto3.resource("dynamodb", region_name=REGION).Table(TABLA_PLANES)

app = FastAPI(title="planes-worker")

FACTOR_ACTIVIDAD = {
    "sedentario": 1.2,
    "ligero": 1.375,
    "moderado": 1.55,
    "intenso": 1.725,
    "muy_intenso": 1.9,
}
AJUSTE_OBJETIVO = {"perder_grasa": -500, "mantener": 0, "ganar_musculo": 300}


def calorias_mifflin(datos: dict) -> dict:
    """Mifflin-St Jeor: TMB = 10*peso + 6.25*talla - 5*edad + 5 (hombre) o - 161 (mujer)."""
    peso = float(datos["peso"])
    talla = float(datos["talla"])
    edad = int(datos["edad"])
    tmb = 10 * peso + 6.25 * talla - 5 * edad + (5 if datos["sexo"] == "M" else -161)
    mantenimiento = tmb * FACTOR_ACTIVIDAD.get(datos.get("actividad", "moderado"), 1.55)
    objetivo = mantenimiento + AJUSTE_OBJETIVO.get(datos.get("objetivo", "mantener"), 0)
    return {"tmb": round(tmb), "mantenimiento": round(mantenimiento), "objetivo": round(objetivo)}


def simular_optimizador(segundos: float) -> int:
    """Ocupa CPU de verdad (no sleep) para que el autoescalado por CPU se active."""
    fin = time.time() + segundos
    vueltas = 0
    x = 0
    while time.time() < fin:
        for i in range(10_000):
            x = (x * 31 + i) % 1_000_003
        vueltas += 1
    return vueltas


@app.middleware("http")
async def log_peticion(request: Request, call_next):
    inicio = time.time()
    respuesta = await call_next(request)
    ms = (time.time() - inicio) * 1000
    print(f"{request.method} {request.url.path} {respuesta.status_code} {ms:.1f} ms", flush=True)
    return respuesta


# El daemon del worker de Beanstalk revisa la salud en "/" por defecto
@app.get("/")
@app.get("/salud")
def salud():
    return {"estado": "ok", "app": "planes-worker"}


# Función normal (no async): FastAPI la corre en un hilo aparte y no bloquea /salud
@app.post("/procesar")
def procesar(mensaje: dict):
    try:
        plan_id = mensaje["id"]
        datos = mensaje["datos"]
        inicio = time.time()
        vueltas = simular_optimizador(SEGUNDOS_CPU)
        calorias = calorias_mifflin(datos)
        tabla_planes.update_item(
            Key={"id": plan_id},
            UpdateExpression="SET estado = :e, calorias = :c, generado = :g, segundos = :s",
            ExpressionAttributeValues={
                ":e": "generado",
                ":c": calorias,
                ":g": datetime.now(timezone.utc).isoformat(),
                ":s": Decimal(str(round(time.time() - inicio, 2))),
            },
        )
        print(f"plan {plan_id} generado: {calorias} ({vueltas} vueltas de CPU)", flush=True)
        return {"id": plan_id, "estado": "generado", "calorias": calorias}
    except Exception as error:
        # 500 hace que Beanstalk reintente y, tras 3 intentos, mande el mensaje a la DLQ
        print(f"error procesando mensaje {mensaje}: {error!r}", flush=True)
        return JSONResponse(status_code=500, content={"error": str(error)})
