# support for RelaxNG validation
from lxml.includes cimport relaxng

cdef object _rnc2rng
try:
    import rnc2rng as _rnc2rng
except ImportError:
    _rnc2rng = None


class RelaxNGError(LxmlError):
    u"""Base class for RelaxNG errors.
    """
    pass


class RelaxNGParseError(RelaxNGError):
    u"""Error while parsing an XML document as RelaxNG.
    """
    pass


class RelaxNGValidateError(RelaxNGError):
    u"""Error while validating an XML document with a RelaxNG schema.
    """
    pass


################################################################################
# RelaxNG

cdef class RelaxNG(_Validator):
    u"""RelaxNG(self, etree=None, file=None)
    Turn a document into a Relax NG validator.

    Either pass a schema as Element or ElementTree, or pass a file or
    filename through the ``file`` keyword argument.
    """
    cdef relaxng.xmlRelaxNG* _c_schema
    def __cinit__(self):
        self._c_schema = NULL

    def __init__(self, etree=None, *, file=None):
        cdef _Document doc
        cdef _Element root_node
        cdef xmlDoc* fake_c_doc = NULL
        cdef relaxng.xmlRelaxNGParserCtxt* parser_ctxt
        _Validator.__init__(self)
        if etree is not None:
            doc = _documentOrRaise(etree)
            root_node = _rootNodeOrRaise(etree)
            fake_c_doc = _fakeRootDoc(doc._c_doc, root_node._c_node)
            parser_ctxt = relaxng.xmlRelaxNGNewDocParserCtxt(fake_c_doc)
        elif file is not None:
            if _isString(file):
                if file.lower().endswith('.rnc'):
                    if _rnc2rng is None:
                        raise RelaxNGParseError(
                            'compact syntax not supported (please install rnc2rng)')
                    rng_data = _rnc2rng.dumps(_rnc2rng.load(file))
                    doc = _parseMemoryDocument(rng_data, parser=None, url=None)
                    root_node = doc.getroot()
                    fake_c_doc = _fakeRootDoc(doc._c_doc, root_node._c_node)
                    parser_ctxt = relaxng.xmlRelaxNGNewDocParserCtxt(fake_c_doc)
                else:
                    doc = None
                    filename = _encodeFilename(file)
                    with self._error_log:
                        parser_ctxt = relaxng.xmlRelaxNGNewParserCtxt(_cstr(filename))
            elif (_getFilenameForFile(file) or '').lower().endswith('.rnc'):
                rng_data = _rnc2rng.dumps(_rnc2rng.load(file))
                doc = _parseMemoryDocument(rng_data, parser=None, url=None)
                root_node = doc.getroot()
                fake_c_doc = _fakeRootDoc(doc._c_doc, root_node._c_node)
                parser_ctxt = relaxng.xmlRelaxNGNewDocParserCtxt(fake_c_doc)
            else:
                doc = _parseDocument(file, parser=None, base_url=None)
                parser_ctxt = relaxng.xmlRelaxNGNewDocParserCtxt(doc._c_doc)
        else:
            raise RelaxNGParseError, u"No tree or file given"

        if parser_ctxt is NULL:
            if fake_c_doc is not NULL:
                _destroyFakeDoc(doc._c_doc, fake_c_doc)
            raise RelaxNGParseError(
                self._error_log._buildExceptionMessage(
                    u"Document is not parsable as Relax NG"),
                self._error_log)

        relaxng.xmlRelaxNGSetParserStructuredErrors(
            parser_ctxt, _receiveError, <void*>self._error_log)
        self._c_schema = relaxng.xmlRelaxNGParse(parser_ctxt)

        relaxng.xmlRelaxNGFreeParserCtxt(parser_ctxt)
        if self._c_schema is NULL:
            if fake_c_doc is not NULL:
                _destroyFakeDoc(doc._c_doc, fake_c_doc)
            raise RelaxNGParseError(
                self._error_log._buildExceptionMessage(
                    u"Document is not valid Relax NG"),
                self._error_log)
        if fake_c_doc is not NULL:
            _destroyFakeDoc(doc._c_doc, fake_c_doc)

    def __dealloc__(self):
        relaxng.xmlRelaxNGFree(self._c_schema)

    def __call__(self, etree):
        u"""__call__(self, etree)

        Validate doc using Relax NG.

        Returns true if document is valid, false if not."""
        cdef _Document doc
        cdef _Element root_node
        cdef xmlDoc* c_doc
        cdef relaxng.xmlRelaxNGValidCtxt* valid_ctxt
        cdef int ret

        assert self._c_schema is not NULL, "RelaxNG instance not initialised"
        doc = _documentOrRaise(etree)
        root_node = _rootNodeOrRaise(etree)

        valid_ctxt = relaxng.xmlRelaxNGNewValidCtxt(self._c_schema)
        if valid_ctxt is NULL:
            raise MemoryError()

        try:
            self._error_log.clear()
            relaxng.xmlRelaxNGSetValidStructuredErrors(
                valid_ctxt, _receiveError, <void*>self._error_log)
            c_doc = _fakeRootDoc(doc._c_doc, root_node._c_node)
            with nogil:
                ret = relaxng.xmlRelaxNGValidateDoc(valid_ctxt, c_doc)
            _destroyFakeDoc(doc._c_doc, c_doc)
        finally:
            relaxng.xmlRelaxNGFreeValidCtxt(valid_ctxt)

        if ret == -1:
            raise RelaxNGValidateError(
                u"Internal error in Relax NG validation",
                self._error_log)
        if ret == 0:
            return True
        else:
            return False

    @classmethod
    def from_rnc_string(cls, src):
        rng_str = _rnc2rng.dumps(_rnc2rng.loads(src))
        return cls(_parseMemoryDocument(rng_str, parser=None, url=None))
