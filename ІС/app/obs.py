"""Спільна обсервабельність: трейси -> Tempo (OTLP), логи -> stdout (їх забирає Alloy у Loki).
У кожен рядок логу пишемо trace_id, щоб у Grafana перейти з логу в трейс."""
import logging

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


class TraceIdFilter(logging.Filter):
    def filter(self, record):
        ctx = trace.get_current_span().get_span_context()
        record.trace_id = format(ctx.trace_id, "032x") if ctx.is_valid else "-"
        return True


def setup(service):
    provider = TracerProvider(resource=Resource.create({"service.name": service}))
    # адреса Tempo береться зі змінної OTEL_EXPORTER_OTLP_ENDPOINT
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    handler = logging.StreamHandler()
    handler.addFilter(TraceIdFilter())
    logging.basicConfig(
        level=logging.INFO,
        handlers=[handler],
        format=f'ts=%(asctime)s level=%(levelname)s service={service} trace_id=%(trace_id)s msg="%(message)s"',
    )
    return trace.get_tracer(service), logging.getLogger(service)
