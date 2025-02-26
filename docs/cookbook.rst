========
Cookbook
========

.. epigraph::

    When in doubt, use Hunter.

Walkthrough
===========

Sometimes you just want to get an overview of an unfamiliar application code, eg: only see calls/returns/exceptions.

In this situation, you could use something like
``~Q(kind="line"),~Q(module_in=["six","pkg_resources"]),~Q(filename=""),stdlib=False``. Lets break that down:

* ``~Q(kind="line")`` means skip line events (``~`` is a negation of the filter).
* ``stdlib=False`` means we don't want to see anything from stdlib.
* ``~Q(module_in=["six","pkg_resources")]`` means we're tired of seeing stuff from those modules in site-packages.
* ``~Q(filename="")`` is necessary for filtering out events that come from code without a source (like the interpreter
  bootstrap stuff).

You would run the application (in Bash) like:

.. sourcecode:: shell

    PYTHONHUNTER='~Q(kind="line"),~Q(module_in=["six","pkg_resources"]),~Q(filename=""),stdlib=False' myapp (or python myapp.py)


Additionally you can also add a depth filter (eg: ``depth_lt=10``) to avoid too deep output.

Packaging
=========

I frequently use Hunter to figure out how distutils/setuptools work. It's very hard to figure out what's going on by just
looking at the code - lots of stuff happens at runtime. If you ever tried to write a custom command you know what I mean.

To show everything that is being run:

.. sourcecode:: shell

    PYTHONHUNTER='module_startswith=["setuptools", "distutils", "wheel"]' python setup.py bdist_wheel

If you want too see some interesting variables:

.. sourcecode:: shell

    PYTHONHUNTER='module_startswith=["setuptools", "distutils", "wheel"], actions=[CodePrinter, VarsPrinter("self.bdist_dir")]' python setup.py bdist_wheel

Typical
=======

Normally you'd only want to look at your code. For that purpose, there's the ``stdlib`` option. Set it to ``False``.

Building a bit on the previous example, if I have a ``build`` Distutils command and I only want to see my code then I'd run
this:

.. sourcecode:: shell

    PYTHONHUNTER='stdlib=False' python setup.py build

But this also means I'd be seeing anything from ``site-packages``. I could filter on only the events from the current
directory (assuming the filename is going to be a relative path):

.. sourcecode:: shell

    PYTHONHUNTER='~Q(filename_startswith="/")' python setup.py build

Needle in the haystack
======================

If the needle might be though the stdlib then you got not choice. But some of the `hay` is very verbose and useless, like
stuff from the ``re`` module.

Note that there are few "hidden" modules like ``sre``, ``sre_parse``, ``sre_compile`` etc. You can filter that out with:

.. sourcecode:: python

    ~Q(module_regex="(re|sre.*)$")

Although filtering out that regex stuff can cut down lots of useless output you usually still get lots of output.

Another way, if you got at least some vague idea of what might be going on is to "grep" for sourcecode. Example, to show all
the code that does something with a ``build_dir`` property:

.. sourcecode:: python

    source_contains=".build_dir"

You could even extend that a bit to dump some variables:

.. sourcecode:: python

    source_contains=".build_dir", actions=[CodePrinter, VarsPrinter("self.build_dir")]


Stop after N calls
==================

Say you want to stop tracing after 1000 events, you'd do this:

.. sourcecode:: python

    ~Q(calls_gt=1000, action=Stop)

..

    Explanation:

        ``Q(calls_gt=1000, action=Stop)`` will translate to ``When(Query(calls_gt=1000), Stop)``

        ``Q(calls_gt=1000)`` will return ``True`` when 1000 call count is hit.

        ``When(something, Stop)`` will call ``Stop`` when ``something`` returns ``True``. However it will also return the result of ``something`` - the net effect being nothing being shown up to 1000 calls. Clearly not what we want ...

        So then we invert the result, ``~When(...)`` is the same as ``Not(When)``.

        This may not seem intuitive but for now it makes internals simpler. If ``When`` would always return ``True`` then
        ``Or(When, When)`` would never run the second ``When`` and we'd need to have all sorts of checks for this. This may
        change in the future however.

"Probe" - lightweight tracing
=============================

Based on Robert Brewer's `FunctionProbe <https://github.com/ionelmc/python-hunter/issues/45#issuecomment-453754832>`_
example.

The use-case is that you'd like to trace a huge application and running a tracer (even a cython one) would have a too
great impact. To solve this you'd start the tracer only in placer where it's actually needed.

To make this work you'd monkeypatch the function that needs the tracing. This example uses aspectlib instead of tricking
the mock library to do arbitrary monkeypatching:

.. sourcecode:: python

    def probe(qualname, *actions, **filters):
        def tracing_decorator(func):
            @functools.wraps(func)
            def tracing_wrapper(*args, **kwargs):
                # create the Tracer manually to avoid spending time in likely useless things like:
                # - loading PYTHONHUNTERCONFIG
                # - setting up the clear_env_var or thread_support options
                # - atexit cleanup registration
                with hunter.Tracer().trace(hunter.When(hunter.Query(**filters), actions)):
                    return func(*args, **kwargs)

            return tracing_wrapper

        aspectlib.weave(qualname, tracing_decorator)  # this does the monkeypatch

Suggested use:

* to get the regular tracing for that function:

  .. sourcecode:: python

        probe('module.func', hunter.VarsPrinter('var1', 'var2'))

* to log some variables at the end of the target function, and nothing deeper:

  .. sourcecode:: python

        probe('module.func', hunter.VarsPrinter('var1', 'var2'), kind="return", depth=0)

Another interesting thing is that you may note that you can reduce the implementation of the ``probe`` function down to
just:

.. sourcecode:: python

    def probe(qualname, *actions, **kwargs):
        aspectlib.weave(qualname, functools.partial(hunter.wrap, actions=actions, **kwargs))

It will work the same, ``hunter.wrap`` being a decorator. However, while ``hunter.wrap`` will enable this convenience
to trace just inside the target function (``local`` mode):

.. sourcecode:: python

    probe('module.func', local=True)

... it will also add a lot of extra filtering to trim irrelevant events from around the function (like return from
tracer setup, and the internals of the decorator), in addition to what ``hunter.trace`` does. Not exactly lightweight.


