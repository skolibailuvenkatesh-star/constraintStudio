/**
 * @description CML Generator V2 — Import-First design.
 *
 * Flow:
 *   1. Collect all Product2 IDs from snippets
 *   2. Bulk fetch product hierarchies (3 queries, no SOQL in loops)
 *   3. Build full CML structure from hierarchy (matching Visual Builder format)
 *   4. Inject snippet constraints/annotations into the relevant types
 *   5. Generate CML string
 *   6. Deploy (BLOB + ExpressionSetConstraintObj + Activate)
 *
 * CML Format (matches Visual Builder pcmGenerator.js):
 *   - Type names: PascalCase product name (e.g., LaptopProBundle)
 *   - Relations: lowercase child type name (e.g., relation mouse : Mouse[0..1])
 *   - Defaults: `default TypeName(qty);` inside relation body
 *   - Inheritance: all non-group types inherit from LineItem (declared as empty base type)
 *   - Groups: @(minInstanceQty = 0, maxInstanceQty = 999) type AccessoriesGroup { ... }
 */
public with sharing class CMLGeneratorV2 {

    private static final String ALLOWED_EXPRESSION_SET = 'PCM_All';
    private static final String API_VERSION = 'v65.0';

    // ==================== DATA STRUCTURES ====================

    public class CMLType {
        public String name;
        public String parentTypeName; // e.g., classification name, or null for no inheritance
        public Id referenceObjectId;
        public Boolean isGroup = false;
        public Integer minInstanceQty; // for group types
        public Integer maxInstanceQty; // for group types
        public Map<String, Object> properties; // annotation properties
        public List<CMLAttr> attributes;
        public List<CMLRel> relations;
        public List<String> constraints; // raw CML constraint lines from snippets
        public List<CMLGroupRef> groupReferences; // PCG mode group references

        public CMLType() {
            this.properties = new Map<String, Object>();
            this.attributes = new List<CMLAttr>();
            this.relations = new List<CMLRel>();
            this.constraints = new List<String>();
            this.groupReferences = new List<CMLGroupRef>();
        }
    }

    public class CMLGroupRef {
        public String refName; // lowercase group reference name
        public String groupTypeName; // PascalCase group type name
    }

    public class CMLAttr {
        public String name; // DeveloperName
        public String dataType; // 'string', 'decimal(2)', 'boolean', 'date'
        public List<String> domainValues; // picklist values
        public Map<String, Object> properties; // defaultValue, configurable, etc.
        public Boolean isUserVariable = false; // F-01: true for user-created variables
        public Boolean hasUserAnnotation = false; // F-01: true when user explicitly annotated this attr
        public String defaultValue; // F-01: single default value for inline rendering (e.g., = "Sharath")

        public CMLAttr() {
            this.domainValues = new List<String>();
            this.properties = new Map<String, Object>();
        }
    }

    public class CMLRel {
        public String name; // lowercase child type name
        public String targetTypeName; // PascalCase child type name
        public Integer minCardinality;
        public Integer maxCardinality;
        public List<CMLDefaultComponent> defaultComponents;
        public Id prcId; // for ExpressionSetConstraintObj

        public CMLRel() {
            this.defaultComponents = new List<CMLDefaultComponent>();
        }
    }

    public class CMLDefaultComponent {
        public String typeName;
        public Decimal quantity;
    }

    public class CMLGeneratorException extends Exception {}

    // ==================== NAME UTILITIES ====================

    private static String toPascalCase(String input) {
        if (String.isBlank(input)) return 'Unknown';
        List<String> words = input.split('[^a-zA-Z0-9]+');
        String result = '';
        for (String word : words) {
            if (String.isNotBlank(word)) {
                result += word.substring(0, 1).toUpperCase() + word.substring(1);
            }
        }
        return String.isNotBlank(result) ? result : 'Unknown';
    }

    private static String ensureUniqueName(String baseName, Set<String> usedNames) {
        String name = baseName;
        Integer idx = 1;
        while (usedNames.contains(name)) {
            name = baseName + idx;
            idx++;
        }
        usedNames.add(name);
        return name;
    }

    // ==================== MAIN EXECUTION ====================

    public static String execute() {
        try {
            System.debug('=== CML Generator V2 Started ===');

            // Phase 0: Find ExpressionSet
            ExpressionSetDefinitionVersion esdv = findPCMAllExpressionSet();
            Id expressionSetId = getExpressionSetId();

            // Phase 1: Collect all product IDs from snippets
            Map<String, List<CMLSnippet__c>> snippetsByProduct = collectSnippets();
            Set<Id> allProduct2Ids = new Set<Id>();
            for (String key : snippetsByProduct.keySet()) {
                for (CMLSnippet__c s : snippetsByProduct.get(key)) {
                    if (s.ParentProduct2__c != null) allProduct2Ids.add(s.ParentProduct2__c);
                }
            }
            System.debug('Found snippets for ' + allProduct2Ids.size() + ' products');

            // Phase 2: Bulk fetch product hierarchies (also collects PCG name map)
            Map<Id, String> pcgNameMap = new Map<Id, String>();
            Map<Id, CMLType> typeMap = bulkFetchAndBuildHierarchy(allProduct2Ids, pcgNameMap);
            System.debug('Built hierarchy with ' + typeMap.size() + ' types');

            // Phase 3: Inject snippet constraints and annotations (with ID→name translation)
            injectSnippets(typeMap, snippetsByProduct, pcgNameMap);

            // Phase 4: Prune types that have no snippets and aren't referenced
            pruneUnusedTypes(typeMap);
            System.debug('After pruning: ' + typeMap.size() + ' types');

            // Phase 5: Generate CML string
            String cmlContent = generateCML(typeMap);
            System.debug('Generated CML (' + cmlContent.length() + ' chars):\n' + cmlContent);

            // Phase 6: Deploy
            updateBlob(esdv, cmlContent);
            deleteExpressionSetConstraintObjs(expressionSetId);
            createExpressionSetConstraintObjs(expressionSetId, typeMap);

            // Phase 7: Activate
            try {
                activateCML(expressionSetId, esdv.Id);
            } catch (Exception ex) {
                System.debug(LoggingLevel.WARN, 'Activation failed: ' + ex.getMessage());
            }

            System.debug('=== CML Generator V2 Completed ===');
            return 'CML generated and deployed for ' + typeMap.size() + ' types.';

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CML Generator V2 Error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            throw new CMLGeneratorException('Failed: ' + e.getMessage());
        }
    }

    // ==================== PHASE 1: COLLECT SNIPPETS ====================

    // Store global property lines collected during snippet collection
    private static List<String> globalPropertyLines = new List<String>();
    private static Boolean usePCGMode = true;

    private static Map<String, List<CMLSnippet__c>> collectSnippets() {
        Map<String, List<CMLSnippet__c>> result = new Map<String, List<CMLSnippet__c>>();
        globalPropertyLines = new List<String>();
        usePCGMode = true; // PCG mode is always on

        List<CMLSnippet__c> allSnippets = [
            SELECT Id, CML__c, Type__c, Object__c, Label__c,
                   ParentProduct2__c,
                   ParentProductClassification__c,
                   ParentProductClassificationAttr__c,
                   ParentProductClassificationAttr__r.ProductClassificationId,
                   ParentProductClassificationAttr__r.AttributeDefinitionId,
                   ParentProductClassificationAttr__r.AttributeDefinition.DeveloperName
            FROM CMLSnippet__c
        ];

        // Collect global snippets separately — deduplicate lines across products
        Set<String> seenGlobalLines = new Set<String>();

        for (CMLSnippet__c s : allSnippets) {
            // Handle global property snippets
            if (s.Type__c == 'global' && String.isNotBlank(s.CML__c)) {
                for (String line : s.CML__c.split('\n')) {
                    String trimmed = line.trim();
                    // Detect generation mode
                    if (trimmed.startsWith('// mode:')) {
                        String mode = trimmed.replace('// mode:', '').trim();
                        if ('pcg'.equalsIgnoreCase(mode)) usePCGMode = true;
                        continue;
                    }
                    if (String.isNotBlank(trimmed) && !seenGlobalLines.contains(trimmed)) {
                        seenGlobalLines.add(trimmed);
                        globalPropertyLines.add(trimmed);
                    }
                }
                continue;
            }

            String key;
            if (s.ParentProduct2__c != null) {
                key = 'P2:' + s.ParentProduct2__c;
            } else if (s.ParentProductClassification__c != null) {
                key = 'PC:' + s.ParentProductClassification__c;
            } else if (s.ParentProductClassificationAttr__c != null) {
                key = 'PCA:' + s.ParentProductClassificationAttr__r.ProductClassificationId;
            } else {
                continue;
            }

            if (!result.containsKey(key)) {
                result.put(key, new List<CMLSnippet__c>());
            }
            result.get(key).add(s);
        }

        return result;
    }

    // ==================== PHASE 2: BULK FETCH & BUILD HIERARCHY ====================

    private static Map<Id, CMLType> bulkFetchAndBuildHierarchy(Set<Id> rootProduct2Ids, Map<Id, String> pcgNameMap) {
        Map<Id, CMLType> typeMap = new Map<Id, CMLType>();
        Set<String> usedNames = new Set<String>();

        // Expand: find all products in the hierarchy (root bundles + children recursively)
        Set<Id> allProduct2Ids = new Set<Id>(rootProduct2Ids);
        Set<Id> processedBundles = new Set<Id>();
        Set<Id> bundlesToProcess = new Set<Id>(rootProduct2Ids);

        // Iteratively expand bundles (max 5 levels deep to prevent infinite loops)
        for (Integer depth = 0; depth < 5 && !bundlesToProcess.isEmpty(); depth++) {
            // Query 1: All PCGs for these bundles
            List<ProductComponentGroup> pcgs = [
                SELECT Id, Name, ParentProductId, MinBundleComponents, MaxBundleComponents
                FROM ProductComponentGroup
                WHERE ParentProductId IN :bundlesToProcess
                ORDER BY Name ASC
            ];

            Set<Id> pcgIds = new Set<Id>();
            for (ProductComponentGroup pcg : pcgs) {
                pcgIds.add(pcg.Id);
                pcgNameMap.put(pcg.Id, toPascalCase(pcg.Name));
            }

            if (pcgIds.isEmpty()) break;

            // Query 2: All PRCs for these PCGs
            List<ProductRelatedComponent> prcs = [
                SELECT Id, ProductComponentGroupId, ProductComponentGroup.Name,
                       ProductComponentGroup.ParentProductId,
                       ProductComponentGroup.MinBundleComponents,
                       ProductComponentGroup.MaxBundleComponents,
                       ChildProductId, ChildProduct.Name, ChildProduct.BasedOnId,
                       MinQuantity, MaxQuantity, IsDefaultComponent, Quantity
                FROM ProductRelatedComponent
                WHERE ProductComponentGroupId IN :pcgIds
                ORDER BY ProductComponentGroup.Name, ChildProduct.Name
            ];

            // Collect child product IDs for next iteration
            Set<Id> newChildIds = new Set<Id>();
            for (ProductRelatedComponent prc : prcs) {
                if (prc.ChildProductId != null) {
                    allProduct2Ids.add(prc.ChildProductId);
                    if (!processedBundles.contains(prc.ChildProductId)) {
                        newChildIds.add(prc.ChildProductId);
                    }
                }
            }

            processedBundles.addAll(bundlesToProcess);
            bundlesToProcess = newChildIds; // next level

            // Build types from this level's data
            if (usePCGMode) {
                buildTypesFromHierarchyPCG(pcgs, prcs, typeMap, usedNames);
            } else {
                buildTypesFromHierarchy(pcgs, prcs, typeMap, usedNames);
            }
        }

        // Query 3: All attributes for all products involved (BULK)
        if (!allProduct2Ids.isEmpty()) {
            bulkFetchAttributes(allProduct2Ids, typeMap, usedNames);
        }

        // Ensure root products exist as types even if they have no PCGs
        for (Id p2Id : rootProduct2Ids) {
            ensureProduct2Type(p2Id, typeMap, usedNames);
        }

        // Query 4: Classification attributes for all classification types
        Set<Id> classificationIds = new Set<Id>();
        for (Id key : typeMap.keySet()) {
            CMLType t = typeMap.get(key);
            // Classification types have parentTypeName = 'LineItem' and are referenced
            // by product types. Detect by checking if any product inherits from this type.
            // Simpler: just collect all BasedOnIds from products we've seen
        }
        // Collect classification IDs from all products
        for (Id p2Id : allProduct2Ids) {
            CMLType t = typeMap.get(p2Id);
            if (t != null && t.parentTypeName != 'LineItem') {
                // Find the classification ID in the typeMap by matching name
                for (Id key : typeMap.keySet()) {
                    CMLType candidate = typeMap.get(key);
                    if (candidate.name == t.parentTypeName && key != p2Id) {
                        classificationIds.add(key);
                        break;
                    }
                }
            }
        }
        if (!classificationIds.isEmpty()) {
            bulkFetchClassificationAttributes(classificationIds, typeMap);
        }

        return typeMap;
    }

    private static void buildTypesFromHierarchyPCG(
        List<ProductComponentGroup> pcgs,
        List<ProductRelatedComponent> prcs,
        Map<Id, CMLType> typeMap,
        Set<String> usedNames
    ) {
        // Group PRCs by PCG
        Map<Id, List<ProductRelatedComponent>> prcsByPcg = new Map<Id, List<ProductRelatedComponent>>();
        for (ProductRelatedComponent prc : prcs) {
            if (!prcsByPcg.containsKey(prc.ProductComponentGroupId)) {
                prcsByPcg.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
            }
            prcsByPcg.get(prc.ProductComponentGroupId).add(prc);
        }

        for (ProductComponentGroup pcg : pcgs) {
            Id parentProduct2Id = pcg.ParentProductId;
            List<ProductRelatedComponent> groupPrcs = prcsByPcg.get(pcg.Id);
            if (groupPrcs == null || groupPrcs.isEmpty()) continue;

            // Ensure parent bundle type exists
            CMLType parentType = ensureProduct2Type(parentProduct2Id, typeMap, usedNames);

            // Create group type for this PCG (append "Group" suffix per pcmGenerator convention)
            String baseName = toPascalCase(pcg.Name);
            if (!baseName.endsWith('Group')) {
                baseName += 'Group';
            }
            String groupTypeName = ensureUniqueName(baseName, usedNames);
            CMLType groupType = new CMLType();
            groupType.name = groupTypeName;
            groupType.parentTypeName = null; // Group types do NOT inherit from LineItem
            groupType.referenceObjectId = pcg.Id;
            groupType.isGroup = true;
            groupType.minInstanceQty = pcg.MinBundleComponents != null ? Integer.valueOf(pcg.MinBundleComponents) : 0;
            groupType.maxInstanceQty = pcg.MaxBundleComponents != null ? Integer.valueOf(pcg.MaxBundleComponents) : 9999;
            typeMap.put(pcg.Id, groupType);

            // Add group reference to parent type
            CMLGroupRef gref = new CMLGroupRef();
            gref.groupTypeName = groupTypeName;
            gref.refName = groupTypeName.toLowerCase();
            parentType.groupReferences.add(gref);

            // Create relations from group type to each child product
            for (ProductRelatedComponent prc : groupPrcs) {
                if (prc.ChildProductId == null) continue;

                CMLType childType = ensureProduct2Type(prc.ChildProductId, typeMap, usedNames);
                String relName = childType.name.toLowerCase();

                CMLRel rel = new CMLRel();
                rel.name = relName;
                rel.targetTypeName = childType.name;
                rel.prcId = prc.Id;
                rel.minCardinality = prc.MinQuantity != null ? prc.MinQuantity.intValue() : 0;
                Integer maxQ = prc.MaxQuantity != null ? prc.MaxQuantity.intValue() : null;
                if (maxQ == null) maxQ = 999;
                rel.maxCardinality = maxQ;

                if (prc.IsDefaultComponent == true) {
                    CMLDefaultComponent dc = new CMLDefaultComponent();
                    dc.typeName = childType.name;
                    dc.quantity = prc.Quantity;
                    rel.defaultComponents.add(dc);
                }

                groupType.relations.add(rel);
            }
        }
    }

    private static void buildTypesFromHierarchy(
        List<ProductComponentGroup> pcgs,
        List<ProductRelatedComponent> prcs,
        Map<Id, CMLType> typeMap,
        Set<String> usedNames
    ) {
        // Group PRCs by PCG
        Map<Id, List<ProductRelatedComponent>> prcsByPcg = new Map<Id, List<ProductRelatedComponent>>();
        for (ProductRelatedComponent prc : prcs) {
            if (!prcsByPcg.containsKey(prc.ProductComponentGroupId)) {
                prcsByPcg.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
            }
            prcsByPcg.get(prc.ProductComponentGroupId).add(prc);
        }

        for (ProductComponentGroup pcg : pcgs) {
            Id parentProduct2Id = pcg.ParentProductId;
            List<ProductRelatedComponent> groupPrcs = prcsByPcg.get(pcg.Id);
            if (groupPrcs == null || groupPrcs.isEmpty()) continue;

            // Ensure parent bundle type exists
            CMLType parentType = ensureProduct2Type(parentProduct2Id, typeMap, usedNames);

            // Create relations from parent to each child product
            for (ProductRelatedComponent prc : groupPrcs) {
                if (prc.ChildProductId == null) continue;

                // Ensure child type exists
                CMLType childType = ensureProduct2Type(prc.ChildProductId, typeMap, usedNames);

                // Create relation: name = full lowercase child type name (matches pcmGenerator)
                String relName = childType.name.toLowerCase();

                // Check if relation already exists
                Boolean relExists = false;
                for (CMLRel existing : parentType.relations) {
                    if (existing.prcId == prc.Id) { relExists = true; break; }
                }
                if (relExists) continue;

                CMLRel rel = new CMLRel();
                rel.name = relName;
                rel.targetTypeName = childType.name;
                rel.prcId = prc.Id;
                rel.minCardinality = prc.MinQuantity != null ? prc.MinQuantity.intValue() : 0;
                // Use PRC max, fall back to PCG max, then default 999
                Integer maxQ = prc.MaxQuantity != null ? prc.MaxQuantity.intValue() : null;
                if (maxQ == null && prc.ProductComponentGroup.MaxBundleComponents != null) {
                    maxQ = Integer.valueOf(prc.ProductComponentGroup.MaxBundleComponents);
                }
                if (maxQ == null) maxQ = 999;
                rel.maxCardinality = maxQ;

                // Default component (Visual Builder format)
                if (prc.IsDefaultComponent == true) {
                    CMLDefaultComponent dc = new CMLDefaultComponent();
                    dc.typeName = childType.name;
                    dc.quantity = prc.Quantity;
                    rel.defaultComponents.add(dc);
                }

                parentType.relations.add(rel);
            }
        }
    }

    private static CMLType ensureProduct2Type(Id product2Id, Map<Id, CMLType> typeMap, Set<String> usedNames) {
        if (typeMap.containsKey(product2Id)) return typeMap.get(product2Id);

        // Query product name and classification
        List<Product2> products = [
            SELECT Id, Name, BasedOnId, BasedOn.Name FROM Product2 WHERE Id = :product2Id LIMIT 1
        ];
        if (products.isEmpty()) return null;

        Product2 p = products[0];
        String typeName = ensureUniqueName(toPascalCase(p.Name), usedNames);

        CMLType type = new CMLType();
        type.name = typeName;
        type.referenceObjectId = product2Id;

        // Inherit from ProductClassification if available, otherwise LineItem
        if (p.BasedOnId != null) {
            CMLType classType = ensureClassificationType(p.BasedOnId, p.BasedOn.Name, typeMap, usedNames);
            type.parentTypeName = classType != null ? classType.name : 'LineItem';
        } else {
            type.parentTypeName = 'LineItem';
        }

        typeMap.put(product2Id, type);
        return type;
    }

    private static CMLType ensureClassificationType(Id classificationId, String classificationName, Map<Id, CMLType> typeMap, Set<String> usedNames) {
        if (typeMap.containsKey(classificationId)) return typeMap.get(classificationId);

        String typeName;
        if (String.isNotBlank(classificationName)) {
            typeName = ensureUniqueName(toPascalCase(classificationName), usedNames);
        } else {
            // Fallback: query if name not provided
            List<ProductClassification> pcs = [
                SELECT Id, Name FROM ProductClassification WHERE Id = :classificationId LIMIT 1
            ];
            if (pcs.isEmpty()) return null;
            typeName = ensureUniqueName(toPascalCase(pcs[0].Name), usedNames);
        }

        CMLType type = new CMLType();
        type.name = typeName;
        type.referenceObjectId = classificationId;
        type.parentTypeName = 'LineItem'; // Classification inherits from LineItem

        typeMap.put(classificationId, type);
        return type;
    }

    private static void bulkFetchAttributes(Set<Id> product2Ids, Map<Id, CMLType> typeMap, Set<String> usedNames) {
        // Query all ProductAttributeDefinitions for these products
        List<ProductAttributeDefinition> pads = [
            SELECT Id, Product2Id,
                   AttributeDefinition.DeveloperName,
                   AttributeDefinition.DataType,
                   AttributeDefinition.PicklistId,
                   DefaultValue, IsReadOnly
            FROM ProductAttributeDefinition
            WHERE Product2Id IN :product2Ids
            AND AttributeDefinition.IsActive = true
            ORDER BY Product2Id, AttributeDefinition.DeveloperName
        ];

        // Collect all picklist IDs for bulk fetch
        Set<Id> picklistIds = new Set<Id>();
        for (ProductAttributeDefinition pad : pads) {
            if (pad.AttributeDefinition.PicklistId != null) {
                picklistIds.add(pad.AttributeDefinition.PicklistId);
            }
        }

        // Bulk fetch picklist values
        Map<Id, List<String>> picklistValuesMap = new Map<Id, List<String>>();
        if (!picklistIds.isEmpty()) {
            List<AttributePicklistValue> apvs = [
                SELECT Id, Name, PicklistId, IsDefault
                FROM AttributePicklistValue
                WHERE PicklistId IN :picklistIds
                ORDER BY PicklistId, Sequence ASC
            ];
            for (AttributePicklistValue apv : apvs) {
                if (!picklistValuesMap.containsKey(apv.PicklistId)) {
                    picklistValuesMap.put(apv.PicklistId, new List<String>());
                }
                picklistValuesMap.get(apv.PicklistId).add(apv.Name);
            }
        }

        // Assign attributes to types
        for (ProductAttributeDefinition pad : pads) {
            CMLType type = typeMap.get(pad.Product2Id);
            if (type == null) continue;

            String dataType = pad.AttributeDefinition.DataType;
            // Skip DATETIME (Visual Builder does this)
            if (dataType == 'DATETIME') continue;

            CMLAttr attr = new CMLAttr();
            attr.name = pad.AttributeDefinition.DeveloperName;
            attr.dataType = mapDataType(dataType);

            // Picklist domain values
            if (pad.AttributeDefinition.PicklistId != null) {
                List<String> vals = picklistValuesMap.get(pad.AttributeDefinition.PicklistId);
                if (vals != null) attr.domainValues = vals;
            }

            // Properties
            if (String.isNotBlank(pad.DefaultValue)) {
                attr.properties.put('defaultValue', pad.DefaultValue);
            }
            if (pad.IsReadOnly == true) {
                attr.properties.put('configurable', false);
            }

            type.attributes.add(attr);
        }
    }

    private static void bulkFetchClassificationAttributes(Set<Id> classificationIds, Map<Id, CMLType> typeMap) {
        List<ProductClassificationAttr> pcas = [
            SELECT Id, ProductClassificationId,
                   AttributeDefinition.DeveloperName,
                   AttributeDefinition.DataType,
                   AttributeDefinition.PicklistId,
                   DefaultValue, IsReadOnly
            FROM ProductClassificationAttr
            WHERE ProductClassificationId IN :classificationIds
            AND AttributeDefinition.IsActive = true
            ORDER BY ProductClassificationId, AttributeDefinition.DeveloperName
        ];

        // Collect picklist IDs
        Set<Id> picklistIds = new Set<Id>();
        for (ProductClassificationAttr pca : pcas) {
            if (pca.AttributeDefinition.PicklistId != null) {
                picklistIds.add(pca.AttributeDefinition.PicklistId);
            }
        }

        // Bulk fetch picklist values
        Map<Id, List<String>> picklistValuesMap = new Map<Id, List<String>>();
        if (!picklistIds.isEmpty()) {
            List<AttributePicklistValue> apvs = [
                SELECT Id, Name, PicklistId
                FROM AttributePicklistValue
                WHERE PicklistId IN :picklistIds
                ORDER BY PicklistId, Sequence ASC
            ];
            for (AttributePicklistValue apv : apvs) {
                if (!picklistValuesMap.containsKey(apv.PicklistId)) {
                    picklistValuesMap.put(apv.PicklistId, new List<String>());
                }
                picklistValuesMap.get(apv.PicklistId).add(apv.Name);
            }
        }

        // Assign attributes to classification types
        for (ProductClassificationAttr pca : pcas) {
            CMLType type = typeMap.get(pca.ProductClassificationId);
            if (type == null) continue;

            String dataType = pca.AttributeDefinition.DataType;
            if (dataType == 'DATETIME') continue;

            CMLAttr attr = new CMLAttr();
            attr.name = pca.AttributeDefinition.DeveloperName;
            attr.dataType = mapDataType(dataType);

            if (pca.AttributeDefinition.PicklistId != null) {
                List<String> vals = picklistValuesMap.get(pca.AttributeDefinition.PicklistId);
                if (vals != null) attr.domainValues = vals;
            }

            if (String.isNotBlank(pca.DefaultValue)) {
                attr.properties.put('defaultValue', pca.DefaultValue);
            }
            if (pca.IsReadOnly == true) {
                attr.properties.put('configurable', false);
            }

            type.attributes.add(attr);
        }
    }

    private static String mapDataType(String sfDataType) {
        if (sfDataType == 'Number' || sfDataType == 'NUMBER') return 'decimal(2)';
        if (sfDataType == 'CURRENCY' || sfDataType == 'PERCENT') return 'decimal(2)';
        if (sfDataType == 'CHECKBOX' || sfDataType == 'BOOLEAN') return 'boolean';
        if (sfDataType == 'DATE') return 'date';
        return 'string'; // TEXT, PICKLIST, etc.
    }

    // ==================== PHASE 3: INJECT SNIPPETS ====================

    private static void injectSnippets(Map<Id, CMLType> typeMap, Map<String, List<CMLSnippet__c>> snippetsByProduct, Map<Id, String> pcgNameMap) {
        // Build ID→name translation map once
        Map<String, String> idToNameMap = buildIdTranslationMap(typeMap, pcgNameMap);

        for (String key : snippetsByProduct.keySet()) {
            List<CMLSnippet__c> snippets = snippetsByProduct.get(key);

            for (CMLSnippet__c s : snippets) {
                if (String.isBlank(s.CML__c)) continue;

                // Strip @(...) annotation prefix, check if active
                String cmlCode = stripAnnotationPrefix(s.CML__c);
                if (!isSnippetActive(s.CML__c)) continue;

                if (s.Object__c == 'Product2' && s.Type__c == 'constraint' && s.ParentProduct2__c != null) {
                    CMLType type = typeMap.get(s.ParentProduct2__c);
                    if (type != null && String.isNotBlank(cmlCode)) {
                        // Translate IDs to PascalCase names
                        String translated = translateConstraintIds(cmlCode, idToNameMap);
                        // Ensure constraint ends with semicolon
                        translated = translated.trim();
                        if (!translated.endsWith(';')) translated += ';';
                        type.constraints.add(translated);
                    }
                }
                else if (s.Object__c == 'Product2' && s.Type__c == 'annotation' && s.ParentProduct2__c != null) {
                    CMLType type = typeMap.get(s.ParentProduct2__c);
                    if (type != null) {
                        String raw = s.CML__c;
                        // Type-level annotations (existing)
                        if (raw.contains('virtual') && raw.contains('true')) {
                            type.properties.put('virtual', true);
                        }
                        if (raw.contains('sourceContextNode')) {
                            Pattern p = Pattern.compile('sourceContextNode\\s*=\\s*"([^"]+)"');
                            Matcher m = p.matcher(raw);
                            if (m.find()) {
                                type.properties.put('sourceContextNode', m.group(1));
                            }
                        }
                        // F-01: Attribute-level annotations (Label__c = attribute developer name)
                        if (String.isNotBlank(s.Label__c)) {
                            for (CMLAttr attr : type.attributes) {
                                if (attr.name == s.Label__c) {
                                    parseAnnotationIntoProperties(raw, attr.properties);
                                    attr.hasUserAnnotation = true;
                                    break;
                                }
                            }
                        }
                    }
                }
                // F-01: Variable snippets -> parse into CMLAttr, add to type
                else if (s.Object__c == 'Product2' && s.Type__c == 'variable' && s.ParentProduct2__c != null) {
                    CMLType type = typeMap.get(s.ParentProduct2__c);
                    if (type != null) {
                        CMLAttr varAttr = parseVariableSnippet(s);
                        if (varAttr != null) {
                            type.attributes.add(varAttr);
                        }
                    }
                }
                // Classification-level constraint snippets
                else if (s.Object__c == 'ProductClassification' && s.Type__c == 'constraint' && s.ParentProductClassification__c != null) {
                    CMLType classType = typeMap.get(s.ParentProductClassification__c);
                    if (classType != null && String.isNotBlank(cmlCode)) {
                        String translated = translateConstraintIds(cmlCode, idToNameMap);
                        translated = translated.trim();
                        if (!translated.endsWith(';')) translated += ';';
                        classType.constraints.add(translated);
                    }
                }
                // Classification-level annotation snippets
                else if (s.Object__c == 'ProductClassification' && s.Type__c == 'annotation' && s.ParentProductClassification__c != null) {
                    CMLType classType = typeMap.get(s.ParentProductClassification__c);
                    if (classType != null) {
                        parseAnnotationIntoProperties(s.CML__c, classType.properties);
                    }
                }
                // Classification attribute-level annotation snippets
                else if (s.Object__c == 'ProductClassificationAttr' && s.Type__c == 'annotation') {
                    Id classId = s.ParentProductClassificationAttr__r?.ProductClassificationId;
                    String attrDevName = s.ParentProductClassificationAttr__r?.AttributeDefinition?.DeveloperName;
                    if (classId != null && attrDevName != null) {
                        // First try classification type, then fall through to all types
                        CMLType classType = typeMap.get(classId);
                        if (classType != null) {
                            for (CMLAttr attr : classType.attributes) {
                                if (attr.name == attrDevName) {
                                    parseAnnotationIntoProperties(s.CML__c, attr.properties);
                                }
                            }
                        }
                        // Also apply to product types that inherit these attributes
                        for (CMLType type : typeMap.values()) {
                            if (type.referenceObjectId == classId) continue; // skip classification type itself
                            for (CMLAttr attr : type.attributes) {
                                if (attr.name == attrDevName) {
                                    parseAnnotationIntoProperties(s.CML__c, attr.properties);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     * Strip @(...) annotation prefix from snippet CML.
     * e.g., "@(active=true)\nconstraint(...)" → "constraint(...)"
     */
    private static String stripAnnotationPrefix(String cml) {
        if (String.isBlank(cml)) return cml;
        // Remove leading @(...) and any whitespace/newline after it
        String stripped = cml.replaceFirst('^@\\([^)]*\\)\\s*', '');
        return stripped.trim();
    }

    /**
     * Check if snippet is active from its @(...) annotation.
     * Default = true if no annotation or no active= found.
     */
    private static Boolean isSnippetActive(String cml) {
        if (String.isBlank(cml)) return true;
        Pattern p = Pattern.compile('^@\\(([^)]*)\\)');
        Matcher m = p.matcher(cml);
        if (m.find()) {
            String annotationContent = m.group(1);
            if (annotationContent.contains('active=false')) return false;
        }
        return true;
    }

    /**
     * F-01: Parse a variable CMLSnippet into a CMLAttr.
     * CML format: "@(defaultValue="10")\ndecimal(2) MyVar;" or "string MyVar = ["a", "b"];"
     */
    private static CMLAttr parseVariableSnippet(CMLSnippet__c varSnippet) {
        String cml = varSnippet.CML__c;
        if (String.isBlank(cml)) return null;

        CMLAttr attr = new CMLAttr();
        attr.name = varSnippet.Label__c;
        attr.isUserVariable = true;

        // Parse annotation properties from @(...) prefix
        Pattern annPattern = Pattern.compile('^@\\(([^)]*)\\)');
        Matcher annMatcher = annPattern.matcher(cml.trim());
        if (annMatcher.find()) {
            parseAnnotationIntoProperties(annMatcher.group(1), attr.properties);
            attr.properties.remove('active');
        }

        // Parse declaration (after stripping annotation)
        String declaration = stripAnnotationPrefix(cml).trim().replaceFirst(';$', '').trim();
        Integer spaceIdx = declaration.indexOf(' ');
        if (spaceIdx > 0) {
            attr.dataType = declaration.substring(0, spaceIdx).trim();
            String rest = declaration.substring(spaceIdx + 1).trim();

            // Check for default value or domain values
            Integer eqIdx = rest.indexOf('=');
            if (eqIdx > 0) {
                String valPart = rest.substring(eqIdx + 1).trim();
                if (valPart.startsWith('[') && valPart.endsWith(']')) {
                    // Domain values: = ["a", "b"]
                    String domainInner = valPart.substring(1, valPart.length() - 1);
                    for (String val : domainInner.split(',')) {
                        String trimVal = val.trim().replaceAll('^"|"$', '');
                        if (String.isNotBlank(trimVal)) {
                            attr.domainValues.add(trimVal);
                        }
                    }
                } else {
                    // Single default value: = "Sharath"
                    attr.defaultValue = valPart.replaceAll('^"|"$', '');
                }
            }
        } else {
            attr.dataType = 'string';
        }

        return attr;
    }

    /**
     * Build a map of ID-based patterns → PascalCase/lowercase names for constraint translation.
     * Handles: REL_ProductRelatedComponent_<id>, REL_ProductComponentGroup_<id>, Product2_<id>
     */
    private static Map<String, String> buildIdTranslationMap(Map<Id, CMLType> typeMap, Map<Id, String> pcgNameMap) {
        Map<String, String> translationMap = new Map<String, String>();

        // Product2 ID → PascalCase type name
        for (Id p2Id : typeMap.keySet()) {
            CMLType t = typeMap.get(p2Id);
            translationMap.put('Product2_' + p2Id, t.name);
        }

        // PRC ID → lowercase relation name (from all types' relations)
        for (CMLType t : typeMap.values()) {
            for (CMLRel rel : t.relations) {
                if (rel.prcId != null) {
                    translationMap.put('REL_ProductRelatedComponent_' + rel.prcId, rel.name);
                }
            }
        }

        // PCG ID → full lowercase name
        for (Id pcgId : pcgNameMap.keySet()) {
            String pcgPascal = pcgNameMap.get(pcgId);
            translationMap.put('REL_ProductComponentGroup_' + pcgId, pcgPascal.toLowerCase());
        }

        return translationMap;
    }

    /**
     * Replace ID-based references in constraint text with PascalCase/lowercase names.
     */
    private static String translateConstraintIds(String cml, Map<String, String> idToNameMap) {
        String result = cml;
        for (String idPattern : idToNameMap.keySet()) {
            if (result.contains(idPattern)) {
                result = result.replace(idPattern, idToNameMap.get(idPattern));
            }
        }
        return result;
    }

    // ==================== PHASE 3.5: PRUNE UNUSED TYPES ====================

    /**
     * Remove types that have no snippet constraints/annotations and aren't
     * referenced in any constraint text. Keep only what's needed for CML.
     */
    private static void pruneUnusedTypes(Map<Id, CMLType> typeMap) {
        // Build name→Id lookup for quick resolution
        Map<String, Id> nameToId = new Map<String, Id>();
        for (Id key : typeMap.keySet()) {
            nameToId.put(typeMap.get(key).name, key);
        }

        // Step 1: Seed — types that have snippet content (constraints or custom properties)
        Set<Id> neededTypeIds = new Set<Id>();
        Set<String> referencedNames = new Set<String>();

        for (Id key : typeMap.keySet()) {
            CMLType t = typeMap.get(key);
            Boolean hasContent = !t.constraints.isEmpty() || !t.properties.isEmpty();

            // F-01: Also seed types that have user variables or user-annotated attributes
            if (!hasContent) {
                for (CMLAttr attr : t.attributes) {
                    if (attr.isUserVariable || attr.hasUserAnnotation) {
                        hasContent = true;
                        break;
                    }
                }
            }

            if (hasContent) {
                neededTypeIds.add(key);
                // Scan constraint text for referenced type/relation/group names
                for (String constraint : t.constraints) {
                    // Match relation[Type] patterns
                    Pattern p = Pattern.compile('(\\w+)\\[(\\w+)\\]');
                    Matcher m = p.matcher(constraint);
                    while (m.find()) {
                        referencedNames.add(m.group(1)); // relation name
                        referencedNames.add(m.group(2)); // type name
                    }
                    // Match dotted group reference paths: groupref.relation[Type]
                    // e.g., "accessories.mouse[Mouse]" or "laptopgroup.laptop[Laptop].Display"
                    Pattern dotP = Pattern.compile('(\\w+)\\.(\\w+)\\[');
                    Matcher dotM = dotP.matcher(constraint);
                    while (dotM.find()) {
                        referencedNames.add(dotM.group(1)); // group reference name
                        referencedNames.add(dotM.group(2)); // relation name inside group
                    }
                    // Match all identifiers to catch attribute references like .Display
                    Pattern idP = Pattern.compile('\\b(\\w+)\\b');
                    Matcher idM = idP.matcher(constraint);
                    while (idM.find()) {
                        referencedNames.add(idM.group(1));
                    }
                }
            }
        }

        // Build lowercase→Id lookup for group reference resolution
        Map<String, Id> lowercaseNameToId = new Map<String, Id>();
        for (Id key : typeMap.keySet()) {
            lowercaseNameToId.put(typeMap.get(key).name.toLowerCase(), key);
        }

        // Step 2: Add types referenced by name in constraint text
        for (Id key : typeMap.keySet()) {
            CMLType t = typeMap.get(key);
            if (referencedNames.contains(t.name) || referencedNames.contains(t.name.toLowerCase())) {
                neededTypeIds.add(key);
            }
            for (CMLRel rel : t.relations) {
                if (referencedNames.contains(rel.name) || referencedNames.contains(rel.targetTypeName)) {
                    neededTypeIds.add(key);
                    if (nameToId.containsKey(rel.targetTypeName)) {
                        neededTypeIds.add(nameToId.get(rel.targetTypeName));
                    }
                }
            }
            // Check group references by lowercase name (constraint text uses lowercase)
            for (CMLGroupRef gr : t.groupReferences) {
                if (referencedNames.contains(gr.refName) || referencedNames.contains(gr.groupTypeName)) {
                    neededTypeIds.add(key); // parent type is needed
                    if (nameToId.containsKey(gr.groupTypeName)) {
                        neededTypeIds.add(nameToId.get(gr.groupTypeName)); // group type is needed
                    }
                }
            }
        }

        // Step 2b: If a product type's parent classification is referenced, keep it
        Set<Id> parentClassIds = new Set<Id>();
        for (Id key : neededTypeIds) {
            CMLType t = typeMap.get(key);
            if (t != null && String.isNotBlank(t.parentTypeName) && t.parentTypeName != 'LineItem' && nameToId.containsKey(t.parentTypeName)
                && (referencedNames.contains(t.parentTypeName) || referencedNames.contains(t.parentTypeName.toLowerCase()))) {
                parentClassIds.add(nameToId.get(t.parentTypeName));
            }
        }
        neededTypeIds.addAll(parentClassIds);

        // Step 3: Transitive closure — follow ONLY referenced paths.
        // Parent classification types are always followed (inheritance).
        // Relations and group references are only followed if their name
        // appears in constraint text (referencedNames).
        Integer prevSize = 0;
        while (neededTypeIds.size() != prevSize) {
            prevSize = neededTypeIds.size();
            Set<Id> toAdd = new Set<Id>();
            for (Id key : neededTypeIds) {
                CMLType t = typeMap.get(key);
                if (t == null) continue;
                // Keep parent classification type ONLY if referenced in constraint text
                if (String.isNotBlank(t.parentTypeName) && t.parentTypeName != 'LineItem' && nameToId.containsKey(t.parentTypeName)
                    && (referencedNames.contains(t.parentTypeName) || referencedNames.contains(t.parentTypeName.toLowerCase()))) {
                    toAdd.add(nameToId.get(t.parentTypeName));
                }
                // Only follow relations that are referenced in constraint text
                for (CMLRel rel : t.relations) {
                    if ((referencedNames.contains(rel.name) || referencedNames.contains(rel.targetTypeName))
                        && nameToId.containsKey(rel.targetTypeName)) {
                        toAdd.add(nameToId.get(rel.targetTypeName));
                    }
                }
                // Only follow group references that are referenced in constraint text
                for (CMLGroupRef gr : t.groupReferences) {
                    if ((referencedNames.contains(gr.refName) || referencedNames.contains(gr.groupTypeName))
                        && nameToId.containsKey(gr.groupTypeName)) {
                        toAdd.add(nameToId.get(gr.groupTypeName));
                    }
                }
            }
            neededTypeIds.addAll(toAdd);
        }

        // Step 4: Remove unneeded types
        Set<Id> toRemove = new Set<Id>();
        for (Id key : typeMap.keySet()) {
            if (!neededTypeIds.contains(key)) {
                toRemove.add(key);
            }
        }
        // Collect removed type names so we can fix dangling parent references
        Set<String> removedTypeNames = new Set<String>();
        for (Id key : toRemove) {
            removedTypeNames.add(typeMap.get(key).name);
            typeMap.remove(key);
        }

        // Step 4b: If a type's parent classification was removed, fall back to LineItem
        for (CMLType t : typeMap.values()) {
            if (String.isNotBlank(t.parentTypeName) && removedTypeNames.contains(t.parentTypeName)) {
                t.parentTypeName = 'LineItem';
            }
        }

        // Step 5: Prune relations and group references that point to removed types
        for (CMLType t : typeMap.values()) {
            List<CMLRel> keptRels = new List<CMLRel>();
            for (CMLRel rel : t.relations) {
                if (nameToId.containsKey(rel.targetTypeName) && typeMap.containsKey(nameToId.get(rel.targetTypeName))) {
                    keptRels.add(rel);
                }
            }
            t.relations = keptRels;

            List<CMLGroupRef> keptRefs = new List<CMLGroupRef>();
            for (CMLGroupRef gr : t.groupReferences) {
                if (nameToId.containsKey(gr.groupTypeName) && typeMap.containsKey(nameToId.get(gr.groupTypeName))) {
                    keptRefs.add(gr);
                }
            }
            t.groupReferences = keptRefs;
        }

        // Step 6: Prune attributes not referenced in any constraint text
        // Collect all constraint text into one string for lookup
        String allConstraintText = '';
        for (CMLType t : typeMap.values()) {
            for (String c : t.constraints) {
                allConstraintText += ' ' + c;
            }
        }
        // For each type, keep only attributes mentioned in constraints,
        // plus F-01: user-defined variables and attributes with user annotations
        for (CMLType t : typeMap.values()) {
            List<CMLAttr> keptAttrs = new List<CMLAttr>();
            for (CMLAttr attr : t.attributes) {
                // F-01: Always keep user-defined variables
                if (attr.isUserVariable) {
                    keptAttrs.add(attr);
                    continue;
                }
                // F-01: Keep attributes with user-defined annotations
                if (attr.hasUserAnnotation) {
                    keptAttrs.add(attr);
                    continue;
                }
                // Keep if referenced in constraint text (word-boundary match)
                Pattern attrPattern = Pattern.compile('\\b' + attr.name + '\\b');
                Matcher attrMatcher = attrPattern.matcher(allConstraintText);
                if (attrMatcher.find()) {
                    keptAttrs.add(attr);
                }
            }
            t.attributes = keptAttrs;
        }
    }

    private static void parseAnnotationIntoProperties(String annotation, Map<String, Object> props) {
        // Parse @(key = value, key2 = "value2") format
        Pattern p = Pattern.compile('(\\w+)\\s*=\\s*(?:"([^"]*)"|(\\w+))');
        Matcher m = p.matcher(annotation);
        while (m.find()) {
            String propName = m.group(1);
            String propValue = m.group(2) != null ? m.group(2) : m.group(3);
            if (propValue == 'true') {
                props.put(propName, true);
            } else if (propValue == 'false') {
                props.put(propName, false);
            } else {
                props.put(propName, propValue);
            }
        }
    }

    // ==================== PHASE 4: GENERATE CML ====================

    private static String generateCML(Map<Id, CMLType> typeMap) {
        if (typeMap.isEmpty()) return '// No CML types generated\n';

        // Always include allowMissingRelations
        String cml = 'property allowMissingRelations = "true";\n';

        // User-defined global properties (extern, property, constant declarations)
        if (!globalPropertyLines.isEmpty()) {
            for (String line : globalPropertyLines) {
                cml += line + '\n';
            }
        }

        cml += '\ntype LineItem;\n\n';

        // Identify classification types (types that other types inherit from)
        Set<String> classificationTypeNames = new Set<String>();
        for (CMLType type : typeMap.values()) {
            if (String.isNotBlank(type.parentTypeName) && type.parentTypeName != 'LineItem') {
                classificationTypeNames.add(type.parentTypeName);
            }
        }

        // Output classification types first (products inherit from them)
        for (CMLType type : typeMap.values()) {
            if (classificationTypeNames.contains(type.name)) {
                cml += generateTypeBlock(type);
            }
        }

        // Then group types (PCG mode — must come before product types that reference them)
        for (CMLType type : typeMap.values()) {
            if (type.isGroup && !classificationTypeNames.contains(type.name)) {
                cml += generateTypeBlock(type);
            }
        }

        // Then product types
        for (CMLType type : typeMap.values()) {
            if (!classificationTypeNames.contains(type.name) && !type.isGroup) {
                cml += generateTypeBlock(type);
            }
        }

        return cml;
    }

    private static String generateTypeBlock(CMLType type) {
        String output = '';

        // Group type annotation (@(minInstanceQty = X, maxInstanceQty = Y))
        if (type.isGroup && (type.minInstanceQty != null || type.maxInstanceQty != null)) {
            List<String> groupAnns = new List<String>();
            if (type.minInstanceQty != null) groupAnns.add('minInstanceQty = ' + type.minInstanceQty);
            if (type.maxInstanceQty != null) groupAnns.add('maxInstanceQty = ' + type.maxInstanceQty);
            output += '@(' + String.join(groupAnns, ', ') + ')\n';
        }

        // Custom properties annotation
        if (!type.properties.isEmpty()) {
            output += generateAnnotation(type.properties) + '\n';
        }

        // Type declaration
        output += 'type ' + type.name;
        if (String.isNotBlank(type.parentTypeName)) {
            output += ' : ' + type.parentTypeName;
        }

        // Empty type shorthand
        if (type.attributes.isEmpty() && type.relations.isEmpty() &&
            type.constraints.isEmpty() && type.groupReferences.isEmpty()) {
            return output + ';\n\n';
        }

        output += ' {\n';

        // Attributes
        for (CMLAttr attr : type.attributes) {
            output += generateAttributeLine(attr);
        }

        // Group references (PCG mode)
        for (CMLGroupRef gr : type.groupReferences) {
            output += '    ' + gr.groupTypeName + ' ' + gr.refName + ';\n';
        }

        // Relations
        for (CMLRel rel : type.relations) {
            output += generateRelationBlock(rel);
        }

        // Constraints (from snippets)
        for (String constraint : type.constraints) {
            output += '    ' + constraint + '\n';
        }

        output += '}\n\n';
        return output;
    }

    private static String generateAnnotation(Map<String, Object> props) {
        List<String> entries = new List<String>();
        for (String key : props.keySet()) {
            Object val = props.get(key);
            if (val instanceof String) {
                entries.add(key + ' = "' + String.valueOf(val) + '"');
            } else {
                entries.add(key + ' = ' + String.valueOf(val));
            }
        }
        return '@(' + String.join(entries, ', ') + ')';
    }

    private static String generateAttributeLine(CMLAttr attr) {
        String output = '';

        // Attribute annotation
        if (!attr.properties.isEmpty()) {
            output += '    ' + generateAnnotation(attr.properties) + '\n';
        }

        // Type and name
        output += '    ' + attr.dataType + ' ' + attr.name;

        // Single default value (F-01: e.g., string abc = "Sharath", decimal(2) x = 1.5)
        if (String.isNotBlank(attr.defaultValue)) {
            Boolean needsQuotes = attr.dataType == 'string' || attr.dataType == 'date';
            output += needsQuotes ? ' = "' + attr.defaultValue + '"' : ' = ' + attr.defaultValue;
        }
        // Domain values (picklist)
        else if (!attr.domainValues.isEmpty()) {
            List<String> quoted = new List<String>();
            for (String v : attr.domainValues) {
                quoted.add('"' + v + '"');
            }
            output += ' = [' + String.join(quoted, ', ') + ']';
        }

        output += ';\n';
        return output;
    }

    private static String generateRelationBlock(CMLRel rel) {
        String output = '';

        // Relation declaration
        output += '    relation ' + rel.name + ' : ' + rel.targetTypeName;

        // Cardinality
        Integer minC = rel.minCardinality != null ? rel.minCardinality : 0;
        Integer maxC = rel.maxCardinality != null ? rel.maxCardinality : 999;
        if (minC == maxC) {
            output += '[' + minC + ']';
        } else {
            output += '[' + minC + '..' + maxC + ']';
        }

        // If has default components, use relation body
        if (!rel.defaultComponents.isEmpty()) {
            output += ' {\n';
            for (CMLDefaultComponent dc : rel.defaultComponents) {
                output += '        default ' + dc.typeName;
                if (dc.quantity != null && dc.quantity > 0) {
                    output += '(' + dc.quantity.intValue() + ')';
                }
                output += ';\n';
            }
            output += '    }\n';
        } else {
            output += ';\n';
        }

        return output;
    }

    // ==================== PHASE 5: DEPLOY ====================

    private static ExpressionSetDefinitionVersion findPCMAllExpressionSet() {
        List<ExpressionSetDefinitionVersion> versions = [
            SELECT Id, ConstraintModel, VersionNumber,
                   ExpressionSetDefinition.DeveloperName,
                   ExpressionSetDefinition.Id
            FROM ExpressionSetDefinitionVersion
            WHERE ExpressionSetDefinition.DeveloperName = :ALLOWED_EXPRESSION_SET
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];
        if (versions.isEmpty()) {
            throw new CMLGeneratorException('ExpressionSet "' + ALLOWED_EXPRESSION_SET + '" not found.');
        }
        if (versions[0].ExpressionSetDefinition.DeveloperName != ALLOWED_EXPRESSION_SET) {
            throw new CMLGeneratorException('Safety check failed.');
        }
        return versions[0];
    }

    private static Id getExpressionSetId() {
        List<ExpressionSet> es = [
            SELECT Id FROM ExpressionSet WHERE ApiName = :ALLOWED_EXPRESSION_SET LIMIT 1
        ];
        if (es.isEmpty()) {
            throw new CMLGeneratorException('ExpressionSet "' + ALLOWED_EXPRESSION_SET + '" not found.');
        }
        return es[0].Id;
    }

    private static String getSessionId() {
        String sessionId = UserInfo.getSessionId();
        if (String.isBlank(sessionId)) {
            throw new CMLGeneratorException('Unable to obtain session ID.');
        }
        return sessionId;
    }

    private static void updateBlob(ExpressionSetDefinitionVersion esdv, String cmlContent) {
        String compositeUrl = '/services/data/' + API_VERSION + '/composite/sobjects';
        String fullUrl = URL.getOrgDomainUrl().toExternalForm() + compositeUrl;

        String base64Blob = EncodingUtil.base64Encode(Blob.valueOf(cmlContent));
        base64Blob = base64Blob.replace('"', '\\"');

        String jsonBody = '{"allOrNone":false,"records":[{"attributes":{"type":"ExpressionSetDefinitionVersion"},' +
            '"Id":"' + esdv.Id + '","ConstraintModel":"' + base64Blob + '"}]}';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod('PATCH');
        req.setHeader('Authorization', 'Bearer ' + getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setBody(jsonBody);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 || res.getBody().contains('"success":false')) {
            throw new CMLGeneratorException('BLOB update failed: ' + res.getBody());
        }
    }

    private static void activateCML(Id expressionSetId, Id esdvId) {
        List<ExpressionSetVersion> versions = [
            SELECT Id, VersionNumber FROM ExpressionSetVersion
            WHERE ExpressionSetId = :expressionSetId
            ORDER BY VersionNumber DESC LIMIT 1
        ];
        if (versions.isEmpty()) {
            throw new CMLGeneratorException('ExpressionSetVersion not found.');
        }

        String deployUrl = '/services/data/' + API_VERSION + '/industries/constraints/' +
            expressionSetId + '/versions/' + versions[0].Id;
        String fullUrl = URL.getOrgDomainUrl().toExternalForm() + deployUrl;

        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{}');

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 204) {
            throw new CMLGeneratorException('Activation failed: ' + res.getBody());
        }
    }

    private static void deleteExpressionSetConstraintObjs(Id expressionSetId) {
        List<ExpressionSetConstraintObj> objs = [
            SELECT Id FROM ExpressionSetConstraintObj WHERE ExpressionSetId = :expressionSetId
        ];
        if (!objs.isEmpty()) delete objs;
    }

    private static void createExpressionSetConstraintObjs(Id expressionSetId, Map<Id, CMLType> typeMap) {
        List<ExpressionSetConstraintObj> toCreate = new List<ExpressionSetConstraintObj>();

        for (CMLType type : typeMap.values()) {
            // Skip virtual types
            if (type.properties.containsKey('virtual') && (Boolean) type.properties.get('virtual') == true) {
                continue;
            }

            // Group types → ConstraintModelTagType = 'Group', referenceObjectId = PCG Id
            if (type.isGroup) {
                ExpressionSetConstraintObj groupObj = new ExpressionSetConstraintObj();
                groupObj.ExpressionSetId = expressionSetId;
                groupObj.ReferenceObjectId = type.referenceObjectId; // ProductComponentGroup Id
                groupObj.ConstraintModelTag = type.name;
                groupObj.ConstraintModelTagType = 'Group';
                toCreate.add(groupObj);

                // Port records for relations inside the group type
                for (CMLRel rel : type.relations) {
                    if (rel.prcId != null) {
                        ExpressionSetConstraintObj portObj = new ExpressionSetConstraintObj();
                        portObj.ExpressionSetId = expressionSetId;
                        portObj.ReferenceObjectId = rel.prcId;
                        portObj.ConstraintModelTag = rel.name;
                        portObj.ConstraintModelTagType = 'Port';
                        toCreate.add(portObj);
                    }
                }
                continue;
            }

            // Product/classification types → ConstraintModelTagType = 'Type'
            ExpressionSetConstraintObj typeObj = new ExpressionSetConstraintObj();
            typeObj.ExpressionSetId = expressionSetId;
            typeObj.ReferenceObjectId = type.referenceObjectId;
            typeObj.ConstraintModelTag = type.name;
            typeObj.ConstraintModelTagType = 'Type';
            toCreate.add(typeObj);

            // Relation (Port) records
            for (CMLRel rel : type.relations) {
                if (rel.prcId != null) {
                    ExpressionSetConstraintObj portObj = new ExpressionSetConstraintObj();
                    portObj.ExpressionSetId = expressionSetId;
                    portObj.ReferenceObjectId = rel.prcId;
                    portObj.ConstraintModelTag = rel.name;
                    portObj.ConstraintModelTagType = 'Port';
                    toCreate.add(portObj);
                }
            }
        }

        if (!toCreate.isEmpty()) insert toCreate;
    }
}
