FROM scratch
# RUN executes against the real macOS environment, not a chroot of the image
# (see FINDINGS.md) -- so its paths are relative to WORKDIR/cwd, not the
# eventual image root. COPY's destination is still image-root-relative, same
# as ferry-mkimage today. (No clang here: the golden bundle used to prove this
# has no Xcode CLT installed -- see FINDINGS.md for why that's a separate,
# environment-specific gap, not a limit of the mechanism.)
COPY hello.sh.tmpl src/hello.sh.tmpl
ENV NAME=RUN
RUN sed "s/@NAME@/$NAME/" src/hello.sh.tmpl > hello
RUN chmod +x hello
RUN ./hello
ENTRYPOINT ["/hello"]
