# Task Prompt: F-054 Synthetic C Backend

Implement feature `F-054` by adding a new HIR-native C backend that performs only mechanical translation from VNF-HIR into C text. The backend must not do semantic validation, type-policy decisions, proof checking, or recovery of malformed HIR. Unsupported node wiring should surface as explicit backend-emission diagnostics in generated C output rather than semantic compiler rejection. Integrate this backend into the compile pipeline as the default output backend while keeping the existing HIR echo backend selectable for diagnostics.
