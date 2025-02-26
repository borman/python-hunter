# cython: linetrace=True, language_level=3str
import threading

from cpython cimport pystate
from cpython.ref cimport Py_INCREF
from cpython.ref cimport Py_CLEAR
from cpython.pystate cimport PyThreadState_Get

from ._event cimport Event

from ._predicates cimport fast_And_call
from ._predicates cimport fast_From_call
from ._predicates cimport fast_Not_call
from ._predicates cimport fast_Or_call
from ._predicates cimport fast_Query_call
from ._predicates cimport fast_When_call

from ._predicates cimport And
from ._predicates cimport From
from ._predicates cimport Not
from ._predicates cimport Or
from ._predicates cimport Query
from ._predicates cimport When

from ._actions cimport CodePrinter
from ._actions cimport CallPrinter
from ._actions cimport VarsPrinter

from ._actions cimport fast_CodePrinter_call
from ._actions cimport fast_CallPrinter_call
from ._actions cimport fast_VarsPrinter_call

__all__ = 'Tracer',

cdef tuple KIND_NAMES = ('call', 'exception', 'line', 'return', 'c_call', 'c_exception', 'c_return')


cdef int trace_func(Tracer self, FrameType frame, int kind, PyObject *arg) except -1:
    if frame.f_trace is not <PyObject*> self:
        Py_CLEAR(frame.f_trace)
        Py_INCREF(self)
        frame.f_trace = <PyObject*> self

    handler = self.handler

    if kind == 3 and self.depth > 0:
        self.depth -= 1

    cdef Event event = Event(frame, KIND_NAMES[kind], None if arg is NULL else <object>arg, self)

    if type(handler) is When:
        fast_When_call(<When>handler, event)
    elif type(handler) is CallPrinter:
        fast_CallPrinter_call(<CallPrinter>handler, event)
    elif type(handler) is CodePrinter:
        fast_CodePrinter_call(<CodePrinter>handler, event)
    elif type(handler) is Query:
        fast_Query_call(<Query>handler, event)
    elif type(handler) is From:
        fast_From_call(<From>handler, event)
    elif type(handler) is And:
        fast_And_call(<And>handler, event)
    elif type(handler) is Or:
        fast_Or_call(<Or>handler, event)
    elif type(handler) is Not:
        fast_Not_call(<Not>handler, event)
    elif type(handler) is VarsPrinter:
        fast_VarsPrinter_call(<VarsPrinter>handler, event)
    elif handler is not None:
        handler(event)

    if kind == 0:
        self.depth += 1
        self.calls += 1


cdef class Tracer:
    """
    Tracer object.
    """
    def __cinit__(self, threading_support=None):
        self.handler = None
        self.previous = None
        self._previousfunc = NULL
        self._threading_previous = None
        self.threading_support = threading_support
        self.depth = 0
        self.calls = 0

    def __dealloc__(self):
        cdef PyThreadState *state = PyThreadState_Get()
        if state.c_traceobj is <PyObject *>self:
            self.stop()

    def __repr__(self):
        return '<hunter._tracer.Tracer at 0x%x: threading_support=%s, %s%s%s%s>' % (
            id(self),
            self.threading_support,
            '<stopped>' if self.handler is None else 'handler=',
            '' if self.handler is None else repr(self.handler),
            '' if self.previous is None else ', previous=',
            '' if self.previous is None else repr(self.previous),
        )

    def __call__(self, frame, kind, arg):
        """
        The settrace function.

        .. note::

            This always returns self (drills down) - as opposed to only drilling down when ``predicate(event)`` is True
            because it might match further inside.
        """
        trace_func(self, frame, KIND_NAMES.index(kind), <PyObject *> arg)
        if kind == 'call':
            PyEval_SetTrace(<pystate.Py_tracefunc> trace_func, <PyObject *> self)
        return self

    def trace(self, predicate):
        """
        Starts tracing with the given callable.

        Args:
            predicate (callable that accepts a single :obj:`hunter.Event` argument):
        Return:
            self
        """
        cdef PyThreadState *state = PyThreadState_Get()
        self.handler = predicate
        if self.threading_support is None or self.threading_support:
            self._threading_previous = getattr(threading, '_trace_hook', None)
            threading.settrace(self)
        if state.c_traceobj is NULL:
            self.previous = None
            self._previousfunc = NULL
        else:
            self.previous = <object>(state.c_traceobj)
            self._previousfunc = state.c_tracefunc
        PyEval_SetTrace(<pystate.Py_tracefunc> trace_func, <PyObject *> self)
        return self

    def stop(self):
        """
        Stop tracing. Reinstalls the :ref:`hunter.Tracer.previous` tracer.
        """
        if self.handler is not None:
            if self.previous is None:
                PyEval_SetTrace(NULL, NULL)
            else:
                PyEval_SetTrace(self._previousfunc, <PyObject *> self.previous)
            self.handler = self.previous = None
            self._previousfunc = NULL
            if self.threading_support is None or self.threading_support:
                threading.settrace(self._threading_previous)
                self._threading_previous = None

    def __enter__(self):
        """
        Does nothing. Users are expected to call :func:`hunter.Tracer.trace`.

        Returns: self
        """
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        """
        Wrapper around :func:`hunter.Tracer.stop`. Does nothing with the arguments.
        """
        self.stop()
