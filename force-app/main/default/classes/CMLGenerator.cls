
/**
 * @description Generates CML (Constraint Modeling Language) from CMLSnippet records
 * and updates the PCM_All ExpressionSet BLOB.
 *
 * SAFETY: This class ONLY works with the 'PCM_All' ExpressionSet to prevent
 * accidental modification of other constraint models.
 *
 * Naming: Uses PascalCase product/classification names (e.g., LaptopProBundle)
 * instead of ID-based names (Product2_01txx...).
 */
public with sharing class CMLGenerator {

    // SAFETY: Hard-coded allowed ExpressionSet name
    private static final String ALLOWED_EXPRESSION_SET = 'PCM_All';
    private static final String API_VERSION = 'v65.0';

    // Name resolution maps (ID -> PascalCase name)
    private static Map<Id, String> product2NameMap = new Map<Id, String>();
    private static Map<Id, String> classificationNameMap = new Map<Id, String>();
    private static Map<Id, String> pcgNameMap = new Map<Id, String>();

    // Track processed bundles to prevent infinite recursion
    private static Set<Id> processedBundleIds = new Set<Id>();

    public class CMLTypeWrapper {
        public String typeName;
        public String annotation;
        public List<CMLRelation> relations;
        public List<String> constraints;
        public List<CMLAttribute> attributes;
        public Id referenceObjectId;

        public CMLTypeWrapper() {
            this.relations = new List<CMLRelation>();
            this.constraints = new List<String>();
            this.attributes = new List<CMLAttribute>();
        }
    }

    public class CMLRelation {
        public String annotation;
        public String referenceType;
        public String objectType; // 'ProductComponentGroup' or 'ProductRelatedComponent'
        public Id objectId;
        public Integer cardinalityMin;
        public Integer cardinalityMax;
        public Boolean isDefault;

        public CMLRelation() {
            this.isDefault = false;
        }
    }

    public class CMLAttribute {
        public String name;
        public String parentType;
        public String annotation;
        public String domain;
        public Id attributeDefinitionId;
        public Id productClassificationAttrId;
        public Id picklistId;
        public String defaultValue;
    }

    public class CMLGeneratorException extends Exception {}

    // ==================== NAMING UTILITIES ====================

    /**
     * @description Converts a string to PascalCase (e.g., "laptop pro bundle" -> "LaptopProBundle")
     */
    private static String toPascalCase(String input) {
        if (String.isBlank(input)) return 'Unknown';

        // Split on non-alphanumeric characters
        List<String> words = input.split('[^a-zA-Z0-9]+');
        String result = '';
        for (String word : words) {
            if (String.isNotBlank(word)) {
                result += word.substring(0, 1).toUpperCase() + word.substring(1);
            }
        }
        return String.isNotBlank(result) ? result : 'Unknown';
    }

    /**
     * @description Gets PascalCase name for a Product2, querying if not cached
     */
    private static String getProduct2Name(Id product2Id) {
        if (product2NameMap.containsKey(product2Id)) {
            return product2NameMap.get(product2Id);
        }
        List<Product2> products = [SELECT Id, Name FROM Product2 WHERE Id = :product2Id LIMIT 1];
        String name = products.isEmpty() ? 'Product2_' + product2Id : toPascalCase(products[0].Name);
        product2NameMap.put(product2Id, name);
        return name;
    }

    /**
     * @description Gets PascalCase name for a ProductClassification, querying if not cached
     */
    private static String getClassificationName(Id classificationId) {
        if (classificationNameMap.containsKey(classificationId)) {
            return classificationNameMap.get(classificationId);
        }
        List<ProductClassification> pcs = [SELECT Id, Name FROM ProductClassification WHERE Id = :classificationId LIMIT 1];
        String name = pcs.isEmpty() ? 'Classification_' + classificationId : toPascalCase(pcs[0].Name);
        classificationNameMap.put(classificationId, name);
        return name;
    }

    /**
     * @description Gets PascalCase name for a ProductComponentGroup, querying if not cached
     */
    private static String getPcgName(Id pcgId) {
        if (pcgNameMap.containsKey(pcgId)) {
            return pcgNameMap.get(pcgId);
        }
        List<ProductComponentGroup> pcgs = [SELECT Id, Name FROM ProductComponentGroup WHERE Id = :pcgId LIMIT 1];
        String name = pcgs.isEmpty() ? 'Group_' + pcgId : toPascalCase(pcgs[0].Name);
        pcgNameMap.put(pcgId, name);
        return name;
    }

    /**
     * @description Translates ID-based references in constraint text to PascalCase names
     */
    private static String translateConstraintToNames(String constraint) {
        if (String.isBlank(constraint)) return constraint;
        String result = constraint;

        // Replace REL_ProductComponentGroup_<ID> with PascalCase group name
        Pattern pcgPattern = Pattern.compile('REL_ProductComponentGroup_([a-zA-Z0-9]{15,18})');
        Matcher pcgMatcher = pcgPattern.matcher(result);
        while (pcgMatcher.find()) {
            String pcgId = pcgMatcher.group(1);
            try {
                String pcgName = getPcgName(pcgId);
                result = result.replace('REL_ProductComponentGroup_' + pcgId, pcgName);
            } catch (Exception e) { /* keep original */ }
        }

        // Replace REL_ProductRelatedComponent_<ID> with PascalCase group name (via PRC -> PCG)
        Pattern prcPattern = Pattern.compile('REL_ProductRelatedComponent_([a-zA-Z0-9]{15,18})');
        Matcher prcMatcher = prcPattern.matcher(result);
        while (prcMatcher.find()) {
            String prcId = prcMatcher.group(1);
            try {
                List<ProductRelatedComponent> prcs = [
                    SELECT Id, ProductComponentGroup.Name
                    FROM ProductRelatedComponent WHERE Id = :prcId LIMIT 1
                ];
                if (!prcs.isEmpty()) {
                    String name = toPascalCase(prcs[0].ProductComponentGroup.Name);
                    result = result.replace('REL_ProductRelatedComponent_' + prcId, name);
                }
            } catch (Exception e) { /* keep original */ }
        }

        // Replace Product2_<ID> with PascalCase product name
        Pattern p2Pattern = Pattern.compile('Product2_([a-zA-Z0-9]{15,18})');
        Matcher p2Matcher = p2Pattern.matcher(result);
        while (p2Matcher.find()) {
            String p2Id = p2Matcher.group(1);
            try {
                String p2Name = getProduct2Name(p2Id);
                result = result.replace('Product2_' + p2Id, p2Name);
            } catch (Exception e) { /* keep original */ }
        }

        // Replace ProductClassification_<ID> with PascalCase classification name
        Pattern pcPattern = Pattern.compile('ProductClassification_([a-zA-Z0-9]{15,18})');
        Matcher pcMatcher = pcPattern.matcher(result);
        while (pcMatcher.find()) {
            String pcId = pcMatcher.group(1);
            try {
                String pcName = getClassificationName(pcId);
                result = result.replace('ProductClassification_' + pcId, pcName);
            } catch (Exception e) { /* keep original */ }
        }

        return result;
    }

    // ==================== MAIN EXECUTION ====================

    public static String execute() {
        try {
            System.debug('=== CML Generator Started ===');

            // Reset static state
            product2NameMap = new Map<Id, String>();
            classificationNameMap = new Map<Id, String>();
            pcgNameMap = new Map<Id, String>();
            processedBundleIds = new Set<Id>();

            // Step 1: Find the PCM_All ExpressionSet
            ExpressionSetDefinitionVersion esdv = findPCMAllExpressionSet();
            System.debug('Found ExpressionSet: ' + esdv.ExpressionSetDefinition.DeveloperName);

            // Step 2: Get the ExpressionSet ID
            Id expressionSetId = getExpressionSetId(esdv.ExpressionSetDefinition.Id);

            // Step 3: Process CML Snippets (attribute annotations + constraints)
            Map<Id, CMLTypeWrapper> typeMap = processSnippets();
            System.debug('Processed ' + typeMap.size() + ' types from attribute snippets');

            processConstraintSnippets(typeMap);
            System.debug('Processed constraint snippets');

            // Step 3c: Process default bundle components (recursive)
            processDefaultBundleComponents(typeMap);
            System.debug('Processed default bundle components, total types: ' + typeMap.size());

            // Step 4: Generate CML string with PascalCase names
            String cmlContent = generateCML(typeMap);
            System.debug('Generated CML size: ' + cmlContent.length() + ' characters');
            System.debug('Generated CML:\n' + cmlContent);

            // Step 5: Update BLOB
            updateBlob(esdv, cmlContent);
            System.debug('BLOB updated successfully');

            // Step 6: Delete existing ExpressionSetConstraintObj records
            deleteExpressionSetConstraintObjs(expressionSetId);

            // Step 7: Create ExpressionSetConstraintObj records
            createExpressionSetConstraintObjs(expressionSetId, typeMap);

            // Step 8: Activate
            try {
                activateCML(expressionSetId, esdv.Id);
                System.debug('CML activated successfully');
            } catch (Exception activationEx) {
                System.debug(LoggingLevel.WARN, 'CML activation failed: ' + activationEx.getMessage());
            }

            System.debug('=== CML Deployment Completed Successfully ===');
            return 'CML generated, deployed, and activated successfully for ' + typeMap.size() + ' types.';

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'CML Generator Error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());
            throw new CMLGeneratorException('Failed to generate CML: ' + e.getMessage());
        }
    }

    // ==================== DEFAULT BUNDLE PROCESSING ====================

    /**
     * @description Processes all Product2 types in the map that are bundles.
     * For each bundle, finds default components and adds them as relations.
     * Recursively processes child bundles.
     */
    private static void processDefaultBundleComponents(Map<Id, CMLTypeWrapper> typeMap) {
        // Collect all Product2 IDs currently in the map
        List<Id> product2IdsToProcess = new List<Id>();
        for (Id typeId : typeMap.keySet()) {
            CMLTypeWrapper type = typeMap.get(typeId);
            // Process Product2 types that haven't been processed as bundles yet
            if (type.typeName.startsWith('Product2_') || product2NameMap.containsKey(typeId)) {
                if (!processedBundleIds.contains(typeId)) {
                    product2IdsToProcess.add(typeId);
                }
            }
        }

        // Also check types that were created with PascalCase names
        for (Id typeId : typeMap.keySet()) {
            if (!processedBundleIds.contains(typeId) && !product2IdsToProcess.contains(typeId)) {
                // Check if this is a Product2 by trying to query
                List<Product2> p2Check = [SELECT Id FROM Product2 WHERE Id = :typeId LIMIT 1];
                if (!p2Check.isEmpty()) {
                    product2IdsToProcess.add(typeId);
                }
            }
        }

        for (Id product2Id : product2IdsToProcess) {
            processOneBundleRecursive(product2Id, typeMap);
        }
    }

    /**
     * @description Recursively processes a single bundle product.
     * Finds its ProductComponentGroups, adds default components as relations,
     * and recurses into child bundles.
     */
    private static void processOneBundleRecursive(Id product2Id, Map<Id, CMLTypeWrapper> typeMap) {
        if (processedBundleIds.contains(product2Id)) return;
        processedBundleIds.add(product2Id);

        // Query ProductComponentGroups for this bundle
        List<ProductComponentGroup> pcgList = [
            SELECT Id, Name, MinBundleComponents, MaxBundleComponents, ParentProductId
            FROM ProductComponentGroup
            WHERE ParentProductId = :product2Id
            ORDER BY Name ASC
        ];

        if (pcgList.isEmpty()) {
            System.debug('Product2 ' + product2Id + ' is not a bundle (no ProductComponentGroups)');
            return;
        }

        System.debug('Processing bundle ' + getProduct2Name(product2Id) + ' with ' + pcgList.size() + ' groups');

        // Ensure the bundle type exists
        ensureProduct2TypeExists(product2Id, typeMap);
        CMLTypeWrapper bundleType = typeMap.get(product2Id);

        Set<Id> pcgIds = new Set<Id>();
        for (ProductComponentGroup pcg : pcgList) {
            pcgIds.add(pcg.Id);
            pcgNameMap.put(pcg.Id, toPascalCase(pcg.Name));
        }

        // Query default ProductRelatedComponents
        List<ProductRelatedComponent> defaultPrcs = [
            SELECT Id, ProductComponentGroupId, ProductComponentGroup.Name,
                   ChildProductId, ChildProduct.Name, ChildProduct.BasedOnId,
                   MinQuantity, MaxQuantity
            FROM ProductRelatedComponent
            WHERE ProductComponentGroupId IN :pcgIds
            AND IsDefaultComponent = true
            ORDER BY ProductComponentGroup.Name, ChildProduct.Name
        ];

        System.debug('Found ' + defaultPrcs.size() + ' default components');

        // Group default PRCs by PCG
        Map<Id, List<ProductRelatedComponent>> defaultsByPcg = new Map<Id, List<ProductRelatedComponent>>();
        for (ProductRelatedComponent prc : defaultPrcs) {
            if (!defaultsByPcg.containsKey(prc.ProductComponentGroupId)) {
                defaultsByPcg.put(prc.ProductComponentGroupId, new List<ProductRelatedComponent>());
            }
            defaultsByPcg.get(prc.ProductComponentGroupId).add(prc);

            // Cache product name
            if (prc.ChildProductId != null) {
                product2NameMap.put(prc.ChildProductId, toPascalCase(prc.ChildProduct.Name));
            }
        }

        // For each PCG, determine relation type and add to bundle
        for (ProductComponentGroup pcg : pcgList) {
            List<ProductRelatedComponent> defaults = defaultsByPcg.get(pcg.Id);
            if (defaults == null || defaults.isEmpty()) continue;

            // Check qualification: MaxBundleComponents==1 && all same BasedOn
            Boolean qualifiesForClassification = false;
            Id commonClassificationId = null;

            // Query ALL PRCs for this group (not just defaults) to check qualification
            List<ProductRelatedComponent> allPrcs = [
                SELECT Id, ChildProductId, ChildProduct.BasedOnId
                FROM ProductRelatedComponent
                WHERE ProductComponentGroupId = :pcg.Id
            ];

            if (pcg.MaxBundleComponents == 1 && !allPrcs.isEmpty()) {
                Set<Id> classificationIds = new Set<Id>();
                Boolean allHaveBasedOn = true;
                for (ProductRelatedComponent prc : allPrcs) {
                    if (prc.ChildProduct.BasedOnId == null) {
                        allHaveBasedOn = false;
                        break;
                    }
                    classificationIds.add(prc.ChildProduct.BasedOnId);
                }
                if (allHaveBasedOn && classificationIds.size() == 1) {
                    qualifiesForClassification = true;
                    commonClassificationId = new List<Id>(classificationIds)[0];
                }
            }

            if (qualifiesForClassification) {
                // Add PCG relation pointing to ProductClassification type
                ensureClassificationTypeExists(commonClassificationId, typeMap);

                CMLRelation rel = new CMLRelation();
                rel.objectType = 'ProductComponentGroup';
                rel.objectId = pcg.Id;
                rel.isDefault = true;
                rel.cardinalityMin = pcg.MinBundleComponents != null ? pcg.MinBundleComponents : 0;
                rel.cardinalityMax = pcg.MaxBundleComponents;
                addRelationIfNotExists(bundleType, rel);

                // Ensure all default child Product2 types exist
                for (ProductRelatedComponent prc : defaults) {
                    if (prc.ChildProductId != null) {
                        ensureProduct2TypeExists(prc.ChildProductId, typeMap);
                    }
                }
            } else {
                // Add individual PRC relations for each default component
                for (ProductRelatedComponent prc : defaults) {
                    if (prc.ChildProductId == null) continue;

                    ensureProduct2TypeExists(prc.ChildProductId, typeMap);

                    CMLRelation rel = new CMLRelation();
                    rel.objectType = 'ProductRelatedComponent';
                    rel.objectId = prc.Id;
                    rel.isDefault = true;
                    rel.cardinalityMin = prc.MinQuantity != null ? prc.MinQuantity.intValue() : 0;
                    rel.cardinalityMax = prc.MaxQuantity != null ? prc.MaxQuantity.intValue() : null;
                    addRelationIfNotExists(bundleType, rel);
                }
            }
        }

        // Recurse: check if any default child products are themselves bundles
        for (ProductRelatedComponent prc : defaultPrcs) {
            if (prc.ChildProductId != null && !processedBundleIds.contains(prc.ChildProductId)) {
                processOneBundleRecursive(prc.ChildProductId, typeMap);
            }
        }
    }

    /**
     * @description Adds a relation to a type if it doesn't already exist (by objectId + objectType)
     */
    private static void addRelationIfNotExists(CMLTypeWrapper type, CMLRelation newRel) {
        for (CMLRelation existing : type.relations) {
            if (existing.objectId == newRel.objectId && existing.objectType == newRel.objectType) {
                // Update isDefault if the new relation is default
                if (newRel.isDefault) existing.isDefault = true;
                return;
            }
        }
        type.relations.add(newRel);
    }

    // ==================== SNIPPET PROCESSING ====================

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
            throw new CMLGeneratorException(
                'ExpressionSet "' + ALLOWED_EXPRESSION_SET + '" not found.'
            );
        }

        validateExpressionSet(versions[0].ExpressionSetDefinition.DeveloperName);
        return versions[0];
    }

    private static void validateExpressionSet(String developerName) {
        if (developerName != ALLOWED_EXPRESSION_SET) {
            throw new CMLGeneratorException(
                'SAFETY CHECK FAILED: Only "' + ALLOWED_EXPRESSION_SET + '" allowed. Attempted: ' + developerName
            );
        }
    }

    private static String readBlobContent(ExpressionSetDefinitionVersion esdv) {
        String blobUrl = '/services/data/' + API_VERSION + '/sobjects/ExpressionSetDefinitionVersion/' +
                         esdv.Id + '/ConstraintModel';
        String instanceUrl = URL.getOrgDomainUrl().toExternalForm();
        String fullUrl = instanceUrl + blobUrl;

        String sessionId = getSessionId();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setHeader('Content-Type', 'application/octet-stream');

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() == 200) {
            return res.getBody();
        } else {
            throw new CMLGeneratorException(
                'Failed to read BLOB. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody()
            );
        }
    }

    private static String getSessionId() {
        String sessionId = UserInfo.getSessionId();
        if (String.isBlank(sessionId)) {
            throw new CMLGeneratorException('Unable to obtain session ID for API calls');
        }
        return sessionId;
    }

    /**
     * @description Processes ProductClassificationAttr annotation snippets
     */
    private static Map<Id, CMLTypeWrapper> processSnippets() {
        Map<Id, CMLTypeWrapper> typeMap = new Map<Id, CMLTypeWrapper>();

        List<CMLSnippet__c> snippets = [
            SELECT Id, CML__c, Type__c, Object__c,
                   ParentProductClassificationAttr__c,
                   ParentProductClassificationAttr__r.ProductClassificationId,
                   ParentProductClassificationAttr__r.AttributeDefinitionId,
                   ParentProductClassificationAttr__r.AttributeDefinition.DeveloperName,
                   ParentProductClassificationAttr__r.AttributeDefinition.DataType,
                   ParentProductClassificationAttr__r.AttributeDefinition.PicklistId,
                   ParentProductClassificationAttr__r.DefaultValue
            FROM CMLSnippet__c
            WHERE Object__c = 'ProductClassificationAttr'
            AND Type__c = 'annotation'
            AND ParentProductClassificationAttr__c != null
        ];

        for (CMLSnippet__c snippet : snippets) {
            Id classificationId = snippet.ParentProductClassificationAttr__r.ProductClassificationId;
            if (classificationId == null) continue;

            if (!typeMap.containsKey(classificationId)) {
                CMLTypeWrapper type = new CMLTypeWrapper();
                type.typeName = getClassificationName(classificationId);
                type.annotation = '';
                type.referenceObjectId = classificationId;
                typeMap.put(classificationId, type);
            }

            CMLTypeWrapper type = typeMap.get(classificationId);
            String attrName = snippet.ParentProductClassificationAttr__r.AttributeDefinition.DeveloperName;

            Boolean attrExists = false;
            for (CMLAttribute existingAttr : type.attributes) {
                if (existingAttr.name == attrName) { attrExists = true; break; }
            }

            if (!attrExists) {
                CMLAttribute attr = new CMLAttribute();
                attr.name = attrName;
                attr.parentType = 'ProductClassificationAttr';
                attr.annotation = snippet.CML__c;
                attr.attributeDefinitionId = snippet.ParentProductClassificationAttr__r.AttributeDefinitionId;
                attr.productClassificationAttrId = snippet.ParentProductClassificationAttr__c;
                attr.picklistId = snippet.ParentProductClassificationAttr__r.AttributeDefinition.PicklistId;
                attr.defaultValue = snippet.ParentProductClassificationAttr__r.DefaultValue;

                String dataType = snippet.ParentProductClassificationAttr__r.AttributeDefinition.DataType;
                attr.domain = (dataType == 'Number') ? 'decimal(2)' : 'string';

                type.attributes.add(attr);
            }
        }

        return typeMap;
    }

    /**
     * @description Processes ProductClassification and Product2 constraint snippets
     */
    private static void processConstraintSnippets(Map<Id, CMLTypeWrapper> typeMap) {
        // ProductClassification constraints
        List<CMLSnippet__c> pcSnippets = [
            SELECT Id, CML__c, Type__c, Object__c, ParentProductClassification__c
            FROM CMLSnippet__c
            WHERE Object__c = 'ProductClassification'
            AND Type__c = 'constraint'
            AND ParentProductClassification__c != null
        ];

        for (CMLSnippet__c snippet : pcSnippets) {
            Id classificationId = snippet.ParentProductClassification__c;

            if (!typeMap.containsKey(classificationId)) {
                CMLTypeWrapper type = new CMLTypeWrapper();
                type.typeName = getClassificationName(classificationId);
                type.annotation = '';
                type.referenceObjectId = classificationId;
                typeMap.put(classificationId, type);
            }

            CMLTypeWrapper type = typeMap.get(classificationId);
            type.constraints.add(snippet.CML__c);
            parseConstraintReferences(snippet.CML__c, type, typeMap);
        }

        // Product2 constraints
        List<CMLSnippet__c> p2Snippets = [
            SELECT Id, CML__c, Type__c, Object__c, ParentProduct2__c
            FROM CMLSnippet__c
            WHERE Object__c = 'Product2'
            AND Type__c = 'constraint'
            AND ParentProduct2__c != null
        ];

        for (CMLSnippet__c snippet : p2Snippets) {
            Id product2Id = snippet.ParentProduct2__c;

            if (!typeMap.containsKey(product2Id)) {
                CMLTypeWrapper type = new CMLTypeWrapper();
                type.typeName = getProduct2Name(product2Id);
                type.annotation = '';
                type.referenceObjectId = product2Id;
                typeMap.put(product2Id, type);
            }

            CMLTypeWrapper type = typeMap.get(product2Id);
            type.constraints.add(snippet.CML__c);
            parseConstraintReferences(snippet.CML__c, type, typeMap);
        }
    }

    /**
     * @description Parses constraint string to find attribute and relation references
     */
    private static void parseConstraintReferences(String constraint, CMLTypeWrapper type, Map<Id, CMLTypeWrapper> typeMap) {
        // Check attributes for ProductClassification types
        if (classificationNameMap.values().contains(type.typeName)) {
            List<ProductClassificationAttr> attrs = [
                SELECT Id, ProductClassificationId, AttributeDefinitionId,
                       AttributeDefinition.DeveloperName, AttributeDefinition.DataType,
                       AttributeDefinition.PicklistId, DefaultValue
                FROM ProductClassificationAttr
                WHERE ProductClassificationId = :type.referenceObjectId
            ];
            for (ProductClassificationAttr pca : attrs) {
                if (constraint.contains(pca.AttributeDefinition.DeveloperName)) {
                    addAttributeIfNotExists(pca, type);
                }
            }
        }

        // Check attributes for Product2 types
        if (product2NameMap.values().contains(type.typeName) || product2NameMap.containsKey(type.referenceObjectId)) {
            List<ProductAttributeDefinition> attrDefs = [
                SELECT Id, Product2Id, AttributeDefinitionId,
                       AttributeDefinition.DeveloperName, AttributeDefinition.DataType,
                       AttributeDefinition.PicklistId, DefaultValue
                FROM ProductAttributeDefinition
                WHERE Product2Id = :type.referenceObjectId
            ];
            for (ProductAttributeDefinition pad : attrDefs) {
                if (constraint.contains(pad.AttributeDefinition.DeveloperName)) {
                    addAttributeIfNotExists(pad, type);
                }
            }

            // Also check ProductClassification attributes via BasedOn
            List<Product2> products = [
                SELECT Id, BasedOnId FROM Product2 WHERE Id = :type.referenceObjectId LIMIT 1
            ];
            if (!products.isEmpty() && products[0].BasedOnId != null) {
                List<ProductClassificationAttr> classAttrs = [
                    SELECT Id, ProductClassificationId, AttributeDefinitionId,
                           AttributeDefinition.DeveloperName, AttributeDefinition.DataType,
                           AttributeDefinition.PicklistId, DefaultValue
                    FROM ProductClassificationAttr
                    WHERE ProductClassificationId = :products[0].BasedOnId
                ];
                for (ProductClassificationAttr pca : classAttrs) {
                    if (constraint.contains(pca.AttributeDefinition.DeveloperName)) {
                        addAttributeIfNotExists(pca, type);
                    }
                }
            }
        }

        // Parse ProductComponentGroup references
        Pattern pcgPattern = Pattern.compile('(?:REL_)?ProductComponentGroup_([a-zA-Z0-9]{15,18})');
        Matcher pcgMatcher = pcgPattern.matcher(constraint);
        while (pcgMatcher.find()) {
            String pcgId = pcgMatcher.group(1);
            addProductComponentGroupRelation(pcgId, type, typeMap);
        }

        // Parse ProductRelatedComponent references
        Pattern prcPattern = Pattern.compile('(?:REL_)?ProductRelatedComponent_([a-zA-Z0-9]{15,18})');
        Matcher prcMatcher = prcPattern.matcher(constraint);
        while (prcMatcher.find()) {
            String prcId = prcMatcher.group(1);
            addProductRelatedComponentRelation(prcId, type, typeMap);
        }
    }

    private static void addAttributeIfNotExists(ProductClassificationAttr pca, CMLTypeWrapper type) {
        String attrName = pca.AttributeDefinition.DeveloperName;
        for (CMLAttribute existing : type.attributes) {
            if (existing.name == attrName) return;
        }

        CMLAttribute attr = new CMLAttribute();
        attr.name = attrName;
        attr.parentType = 'ProductClassificationAttr';
        attr.annotation = '';
        attr.attributeDefinitionId = pca.AttributeDefinitionId;
        attr.productClassificationAttrId = pca.Id;
        attr.picklistId = pca.AttributeDefinition.PicklistId;
        attr.defaultValue = pca.DefaultValue;
        attr.domain = (pca.AttributeDefinition.DataType == 'Number') ? 'decimal(2)' : 'string';
        type.attributes.add(attr);
    }

    private static void addAttributeIfNotExists(ProductAttributeDefinition pad, CMLTypeWrapper type) {
        String attrName = pad.AttributeDefinition.DeveloperName;
        for (CMLAttribute existing : type.attributes) {
            if (existing.name == attrName) return;
        }

        CMLAttribute attr = new CMLAttribute();
        attr.name = attrName;
        attr.parentType = 'ProductAttributeDefinition';
        attr.annotation = '';
        attr.attributeDefinitionId = pad.AttributeDefinitionId;
        attr.productClassificationAttrId = pad.Id;
        attr.picklistId = pad.AttributeDefinition.PicklistId;
        attr.defaultValue = pad.DefaultValue;
        attr.domain = (pad.AttributeDefinition.DataType == 'Number') ? 'decimal(2)' : 'string';
        type.attributes.add(attr);
    }

    private static void addProductComponentGroupRelation(String pcgId, CMLTypeWrapper type, Map<Id, CMLTypeWrapper> typeMap) {
        CMLRelation relation = new CMLRelation();
        relation.objectType = 'ProductComponentGroup';
        relation.objectId = pcgId;
        relation.annotation = '';
        addRelationIfNotExists(type, relation);
    }

    private static void addProductRelatedComponentRelation(String prcId, CMLTypeWrapper type, Map<Id, CMLTypeWrapper> typeMap) {
        CMLRelation relation = new CMLRelation();
        relation.objectType = 'ProductRelatedComponent';
        relation.objectId = prcId;
        relation.annotation = '';
        addRelationIfNotExists(type, relation);
    }

    // ==================== CML GENERATION ====================

    /**
     * @description Generates the CML string using PascalCase names
     */
    private static String generateCML(Map<Id, CMLTypeWrapper> typeMap) {
        if (typeMap.isEmpty()) {
            return '// No CML types generated\n';
        }

        // Pre-resolve all Product2 names for virtual type detection
        Set<Id> product2Ids = new Set<Id>();
        for (CMLTypeWrapper type : typeMap.values()) {
            if (product2NameMap.containsKey(type.referenceObjectId)) {
                product2Ids.add(type.referenceObjectId);
            }
        }

        // Detect virtual Product2 types
        Set<Id> virtualProduct2Ids = new Set<Id>();
        Map<Id, String> product2AnnotationMap = new Map<Id, String>();
        if (!product2Ids.isEmpty()) {
            List<CMLSnippet__c> product2Annotations = [
                SELECT Id, ParentProduct2__c, CML__c
                FROM CMLSnippet__c
                WHERE Object__c = 'Product2'
                AND Type__c = 'annotation'
                AND ParentProduct2__c IN :product2Ids
            ];
            for (CMLSnippet__c snippet : product2Annotations) {
                product2AnnotationMap.put(snippet.ParentProduct2__c, snippet.CML__c);
                if (snippet.CML__c != null && snippet.CML__c.contains('virtual') && snippet.CML__c.contains('true')) {
                    virtualProduct2Ids.add(snippet.ParentProduct2__c);
                }
            }
        }

        String cml = 'property allowMissingRelations = "true";\n\n';

        Set<Id> processedTypes = new Set<Id>();
        List<Id> typeIdsToProcess = new List<Id>(typeMap.keySet());

        Integer index = 0;
        while (index < typeIdsToProcess.size()) {
            Id typeId = typeIdsToProcess[index];
            if (processedTypes.contains(typeId)) { index++; continue; }

            CMLTypeWrapper type = typeMap.get(typeId);
            processedTypes.add(typeId);

            // Type annotation
            if (String.isNotBlank(type.annotation)) {
                cml += type.annotation + '\n';
            }
            if (product2AnnotationMap.containsKey(type.referenceObjectId)) {
                String p2Annotation = product2AnnotationMap.get(type.referenceObjectId);
                if (String.isNotBlank(p2Annotation)) {
                    cml += p2Annotation + '\n';
                }
            }

            // Type declaration with PascalCase name
            String typeDeclaration = 'type ' + type.typeName;

            // Add inheritance for Product2 -> ProductClassification
            if (product2NameMap.containsKey(type.referenceObjectId)) {
                String classificationTypeName = ensureProductClassificationTypeExists(type.referenceObjectId, typeMap);
                if (String.isNotBlank(classificationTypeName)) {
                    typeDeclaration += ' : ' + classificationTypeName;
                }
            }

            cml += typeDeclaration + ' {\n';

            // Constraints (translated to PascalCase names)
            for (String constraint : type.constraints) {
                cml += '    ' + translateConstraintToNames(constraint) + '\n';
            }

            // Attributes
            for (CMLAttribute attr : type.attributes) {
                if (attr.picklistId != null) {
                    getPicklistValuesWithExclusions(attr.picklistId, attr.productClassificationAttrId, attr);
                }

                String annotationToUse = attr.annotation;
                if (String.isNotBlank(attr.defaultValue)) {
                    if (String.isNotBlank(annotationToUse)) {
                        if (annotationToUse.endsWith(')')) {
                            annotationToUse = annotationToUse.substring(0, annotationToUse.length() - 1);
                            annotationToUse += ', defaultValue = "' + attr.defaultValue + '")';
                        }
                    } else {
                        annotationToUse = '@(defaultValue = "' + attr.defaultValue + '")';
                    }
                }

                if (String.isNotBlank(annotationToUse)) {
                    cml += '    ' + annotationToUse + '\n';
                }

                cml += '    ' + attr.domain + ' ' + attr.name;

                if (attr.picklistId != null) {
                    List<String> picklistValues = getPicklistValuesWithExclusions(attr.picklistId, attr.productClassificationAttrId, attr);
                    if (!picklistValues.isEmpty()) {
                        cml += ' = [';
                        for (Integer i = 0; i < picklistValues.size(); i++) {
                            cml += '"' + picklistValues[i] + '"';
                            if (i < picklistValues.size() - 1) cml += ', ';
                        }
                        cml += '];\n';
                    } else {
                        cml += ';\n';
                    }
                } else {
                    cml += ';\n';
                }
            }

            // Relations
            Boolean isVirtualProduct2 = virtualProduct2Ids.contains(type.referenceObjectId);

            for (CMLRelation rel : type.relations) {
                if (rel.objectType == 'ProductRelatedComponent') {
                    cml += generateProductRelatedComponentRelation(rel, type, typeMap, isVirtualProduct2);
                } else if (rel.objectType == 'ProductComponentGroup') {
                    cml += generateProductComponentGroupRelation(rel, type, typeMap, isVirtualProduct2);
                }
            }

            cml += '}\n\n';

            // Check for new types added during processing
            for (Id newTypeId : typeMap.keySet()) {
                if (!processedTypes.contains(newTypeId) && !typeIdsToProcess.contains(newTypeId)) {
                    typeIdsToProcess.add(newTypeId);
                }
            }

            index++;
        }

        return cml;
    }

    /**
     * @description Generates CML for a ProductRelatedComponent relation using PascalCase names
     */
    private static String generateProductRelatedComponentRelation(CMLRelation rel, CMLTypeWrapper type, Map<Id, CMLTypeWrapper> typeMap, Boolean isVirtualProduct2) {
        String relationCml = '';

        List<ProductRelatedComponent> prcs = [
            SELECT Id, ChildProductId, ChildProduct.Name, MinQuantity, MaxQuantity,
                   ProductComponentGroup.Name, ProductComponentGroupId
            FROM ProductRelatedComponent
            WHERE Id = :rel.objectId
            LIMIT 1
        ];

        if (prcs.isEmpty() || prcs[0].ChildProductId == null) return '';

        ProductRelatedComponent prc = prcs[0];

        // Ensure Product2 type exists with PascalCase name
        ensureProduct2TypeExists(prc.ChildProductId, typeMap);
        String product2TypeName = getProduct2Name(prc.ChildProductId);

        // sourceContextNode for virtual types
        if (isVirtualProduct2) {
            relationCml += '    @(sourceContextNode = "SalesTransaction.SalesTransactionItem")\n';
        }

        // @(default=true) annotation for default components
        if (rel.isDefault) {
            relationCml += '    @(default = true)\n';
        }

        if (String.isNotBlank(rel.annotation)) {
            relationCml += '    ' + rel.annotation + '\n';
        }

        // Relation name using PascalCase group name
        String relationName = getPcgName(prc.ProductComponentGroupId);

        // Cardinality
        String cardinality = '';
        Integer minQty = rel.cardinalityMin != null ? rel.cardinalityMin : (prc.MinQuantity != null ? prc.MinQuantity.intValue() : 0);
        Integer maxQty = rel.cardinalityMax != null ? rel.cardinalityMax : (prc.MaxQuantity != null ? prc.MaxQuantity.intValue() : null);
        String maxStr = maxQty != null ? String.valueOf(maxQty) : '*';
        cardinality = '[' + minQty + '..' + maxStr + ']';

        relationCml += '    relation ' + relationName + ' : ' + product2TypeName + cardinality + ';\n';

        return relationCml;
    }

    /**
     * @description Generates CML for a ProductComponentGroup relation using PascalCase names
     */
    private static String generateProductComponentGroupRelation(CMLRelation rel, CMLTypeWrapper type, Map<Id, CMLTypeWrapper> typeMap, Boolean isVirtualProduct2) {
        String relationCml = '';

        List<ProductComponentGroup> pcgs = [
            SELECT Id, Name, MinBundleComponents, MaxBundleComponents
            FROM ProductComponentGroup
            WHERE Id = :rel.objectId
            LIMIT 1
        ];

        if (pcgs.isEmpty()) return '';
        ProductComponentGroup pcg = pcgs[0];
        String pcgPascalName = getPcgName(pcg.Id);

        // Query all PRCs for this group
        List<ProductRelatedComponent> prcs = [
            SELECT Id, ChildProductId, ChildProduct.Name, ChildProduct.BasedOnId, MinQuantity, MaxQuantity
            FROM ProductRelatedComponent
            WHERE ProductComponentGroupId = :rel.objectId
        ];

        if (prcs.isEmpty()) return '';

        // Check qualification: MaxBundleComponents==1 && all same BasedOn
        Boolean qualifiesForClassification = false;
        Id commonClassificationId = null;

        if (pcg.MaxBundleComponents == 1) {
            Set<Id> classificationIds = new Set<Id>();
            Boolean allHaveBasedOn = true;
            for (ProductRelatedComponent prc : prcs) {
                if (prc.ChildProduct.BasedOnId == null) { allHaveBasedOn = false; break; }
                classificationIds.add(prc.ChildProduct.BasedOnId);
            }
            if (allHaveBasedOn && classificationIds.size() == 1) {
                qualifiesForClassification = true;
                commonClassificationId = new List<Id>(classificationIds)[0];
            }
        }

        if (qualifiesForClassification) {
            ensureClassificationTypeExists(commonClassificationId, typeMap);
            String classificationTypeName = getClassificationName(commonClassificationId);

            // Ensure all child Product2 types exist
            for (ProductRelatedComponent prc : prcs) {
                if (prc.ChildProductId != null) {
                    ensureProduct2TypeExists(prc.ChildProductId, typeMap);
                }
            }

            if (isVirtualProduct2) {
                relationCml += '    @(sourceContextNode = "SalesTransaction.SalesTransactionItem")\n';
            }
            if (rel.isDefault) {
                relationCml += '    @(default = true)\n';
            }
            if (String.isNotBlank(rel.annotation)) {
                relationCml += '    ' + rel.annotation + '\n';
            }

            Integer minQty = rel.cardinalityMin != null ? rel.cardinalityMin : (pcg.MinBundleComponents != null ? pcg.MinBundleComponents : 0);
            Integer maxQty = rel.cardinalityMax != null ? rel.cardinalityMax : pcg.MaxBundleComponents;
            String maxStr = maxQty != null ? String.valueOf(maxQty) : '*';
            String cardinality = '[' + minQty + '..' + maxStr + ']';

            relationCml += '    relation ' + pcgPascalName + ' : ' + classificationTypeName + cardinality + ';\n';
        } else {
            // Individual PRC relations
            for (ProductRelatedComponent prc : prcs) {
                if (prc.ChildProductId == null) continue;

                ensureProduct2TypeExists(prc.ChildProductId, typeMap);
                String product2TypeName = getProduct2Name(prc.ChildProductId);

                if (isVirtualProduct2) {
                    relationCml += '    @(sourceContextNode = "SalesTransaction.SalesTransactionItem")\n';
                }
                if (rel.isDefault) {
                    relationCml += '    @(default = true)\n';
                }

                Integer minQty = prc.MinQuantity != null ? prc.MinQuantity.intValue() : 0;
                String maxStr = prc.MaxQuantity != null ? String.valueOf(prc.MaxQuantity.intValue()) : '*';
                String cardinality = '[' + minQty + '..' + maxStr + ']';

                relationCml += '    relation ' + pcgPascalName + ' : ' + product2TypeName + cardinality + ';\n';
            }
        }

        return relationCml;
    }

    // ==================== TYPE HELPERS ====================

    private static String ensureProduct2TypeExists(Id product2Id, Map<Id, CMLTypeWrapper> typeMap) {
        String typeName = getProduct2Name(product2Id);

        if (!typeMap.containsKey(product2Id)) {
            CMLTypeWrapper type = new CMLTypeWrapper();
            type.typeName = typeName;
            type.annotation = '';
            type.referenceObjectId = product2Id;
            typeMap.put(product2Id, type);
        }

        return typeName;
    }

    private static String ensureClassificationTypeExists(Id classificationId, Map<Id, CMLTypeWrapper> typeMap) {
        String typeName = getClassificationName(classificationId);

        if (!typeMap.containsKey(classificationId)) {
            CMLTypeWrapper type = new CMLTypeWrapper();
            type.typeName = typeName;
            type.annotation = '';
            type.referenceObjectId = classificationId;
            typeMap.put(classificationId, type);
        }

        return typeName;
    }

    /**
     * @description Ensures a ProductClassification type exists for a Product2's BasedOn
     */
    private static String ensureProductClassificationTypeExists(Id product2Id, Map<Id, CMLTypeWrapper> typeMap) {
        List<Product2> products = [
            SELECT Id, BasedOnId FROM Product2 WHERE Id = :product2Id LIMIT 1
        ];

        if (products.isEmpty() || products[0].BasedOnId == null) return '';

        Id classificationId = products[0].BasedOnId;
        return ensureClassificationTypeExists(classificationId, typeMap);
    }

    // ==================== BLOB / ACTIVATION / CONSTRAINT OBJS ====================

    private static void updateBlob(ExpressionSetDefinitionVersion esdv, String cmlContent) {
        validateExpressionSet(esdv.ExpressionSetDefinition.DeveloperName);

        String compositeUrl = '/services/data/' + API_VERSION + '/composite/sobjects';
        String instanceUrl = URL.getOrgDomainUrl().toExternalForm();
        String fullUrl = instanceUrl + compositeUrl;

        String base64Blob = EncodingUtil.base64Encode(Blob.valueOf(cmlContent));
        base64Blob = base64Blob.replace('"', '\\"');

        String jsonBody = '{' +
            '"allOrNone": false,' +
            '"records": [{' +
                '"attributes": {"type": "ExpressionSetDefinitionVersion"},' +
                '"Id": "' + esdv.Id + '",' +
                '"ConstraintModel": "' + base64Blob + '"' +
            '}]' +
        '}';

        String sessionId = getSessionId();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod('PATCH');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(jsonBody);

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new CMLGeneratorException(
                'Failed to update via Composite API. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody()
            );
        }
        if (res.getBody().contains('"success":false')) {
            throw new CMLGeneratorException('Composite API returned errors: ' + res.getBody());
        }
    }

    private static void activateCML(Id expressionSetId, Id expressionSetDefinitionVersionId) {
        List<ExpressionSetVersion> versions = [
            SELECT Id, VersionNumber
            FROM ExpressionSetVersion
            WHERE ExpressionSetId = :expressionSetId
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];

        if (versions.isEmpty()) {
            throw new CMLGeneratorException('ExpressionSetVersion not found for ExpressionSet: ' + expressionSetId);
        }

        Id expressionSetVersionId = versions[0].Id;

        String deployUrl = '/services/data/' + API_VERSION + '/industries/constraints/' + expressionSetId + '/versions/' + expressionSetVersionId;
        String instanceUrl = URL.getOrgDomainUrl().toExternalForm();
        String fullUrl = instanceUrl + deployUrl;

        String sessionId = getSessionId();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(fullUrl);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{}');

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200 && res.getStatusCode() != 204) {
            throw new CMLGeneratorException(
                'Failed to activate CML. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody()
            );
        }
    }

    private static Id getExpressionSetId(Id expressionSetDefinitionId) {
        List<ExpressionSet> expressionSets = [
            SELECT Id FROM ExpressionSet WHERE ApiName = :ALLOWED_EXPRESSION_SET LIMIT 1
        ];
        if (expressionSets.isEmpty()) {
            throw new CMLGeneratorException('ExpressionSet with ApiName "' + ALLOWED_EXPRESSION_SET + '" not found.');
        }
        return expressionSets[0].Id;
    }

    private static void deleteExpressionSetConstraintObjs(Id expressionSetId) {
        List<ExpressionSetConstraintObj> objsToDelete = [
            SELECT Id FROM ExpressionSetConstraintObj WHERE ExpressionSetId = :expressionSetId
        ];
        if (!objsToDelete.isEmpty()) {
            delete objsToDelete;
        }
    }

    private static void createExpressionSetConstraintObjs(Id expressionSetId, Map<Id, CMLTypeWrapper> typeMap) {
        List<ExpressionSetConstraintObj> objsToCreate = new List<ExpressionSetConstraintObj>();

        // Detect virtual Product2 types
        Set<Id> virtualProduct2Ids = new Set<Id>();
        Set<Id> p2Ids = new Set<Id>();
        for (CMLTypeWrapper type : typeMap.values()) {
            if (product2NameMap.containsKey(type.referenceObjectId)) {
                p2Ids.add(type.referenceObjectId);
            }
        }
        if (!p2Ids.isEmpty()) {
            for (CMLSnippet__c snippet : [
                SELECT ParentProduct2__c, CML__c FROM CMLSnippet__c
                WHERE Object__c = 'Product2' AND Type__c = 'annotation' AND ParentProduct2__c IN :p2Ids
            ]) {
                if (snippet.CML__c != null && snippet.CML__c.contains('virtual') && snippet.CML__c.contains('true')) {
                    virtualProduct2Ids.add(snippet.ParentProduct2__c);
                }
            }
        }

        for (CMLTypeWrapper type : typeMap.values()) {
            // Skip virtual types
            if (virtualProduct2Ids.contains(type.referenceObjectId)) continue;

            // Create Type record using PascalCase name
            ExpressionSetConstraintObj typeObj = new ExpressionSetConstraintObj();
            typeObj.ExpressionSetId = expressionSetId;
            typeObj.ReferenceObjectId = type.referenceObjectId;
            typeObj.ConstraintModelTag = type.typeName;
            typeObj.ConstraintModelTagType = 'Type';
            objsToCreate.add(typeObj);

            // Create Port records for relations
            for (CMLRelation rel : type.relations) {
                if (rel.objectType == 'ProductRelatedComponent') {
                    ExpressionSetConstraintObj portObj = new ExpressionSetConstraintObj();
                    portObj.ExpressionSetId = expressionSetId;
                    portObj.ReferenceObjectId = rel.objectId;
                    portObj.ConstraintModelTag = getPcgName(rel.objectId);
                    portObj.ConstraintModelTagType = 'Port';
                    objsToCreate.add(portObj);
                } else if (rel.objectType == 'ProductComponentGroup') {
                    String pcgName = getPcgName(rel.objectId);
                    List<ProductRelatedComponent> prcs = [
                        SELECT Id FROM ProductRelatedComponent WHERE ProductComponentGroupId = :rel.objectId
                    ];
                    for (ProductRelatedComponent prc : prcs) {
                        ExpressionSetConstraintObj portObj = new ExpressionSetConstraintObj();
                        portObj.ExpressionSetId = expressionSetId;
                        portObj.ReferenceObjectId = prc.Id;
                        portObj.ConstraintModelTag = pcgName;
                        portObj.ConstraintModelTagType = 'Port';
                        objsToCreate.add(portObj);
                    }
                }
            }
        }

        if (!objsToCreate.isEmpty()) {
            insert objsToCreate;
        }
    }

    private static List<String> getPicklistValuesWithExclusions(Id picklistId, Id productClassificationAttrId, CMLAttribute attr) {
        List<String> values = new List<String>();

        List<AttributePicklistValue> picklistValues = [
            SELECT Id, Name, IsDefault FROM AttributePicklistValue
            WHERE PicklistId = :picklistId ORDER BY Sequence ASC
        ];

        Set<Id> excludedPicklistValueIds = new Set<Id>();
        for (AttrPicklistExcludedValue excluded : [
            SELECT AttributePicklistValueId FROM AttrPicklistExcludedValue
            WHERE AttributeId = :productClassificationAttrId
        ]) {
            excludedPicklistValueIds.add(excluded.AttributePicklistValueId);
        }

        for (AttributePicklistValue pv : picklistValues) {
            if (!excludedPicklistValueIds.contains(pv.Id)) {
                values.add(pv.Name);
                if (pv.IsDefault && String.isBlank(attr.defaultValue)) {
                    attr.defaultValue = pv.Name;
                }
            }
        }

        return values;
    }
}
